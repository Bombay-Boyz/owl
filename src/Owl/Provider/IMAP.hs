-- | IMAP adapter (master spec §20). Uses HaskellNet + HaskellNet-SSL
-- (BSD-3-Clause, actively maintained) rather than implementing IMAP
-- itself.
--
-- KNOWN, DISCLOSED GAP: OAuth2 login for IMAP is not supported here.
-- HaskellNet's IMAP-side AuthType (Network.HaskellNet.Auth.AuthType =
-- PLAIN | LOGIN | CRAM_MD5) has no XOAUTH2 constructor, unlike its
-- SMTP-side AuthType, which does. connectImap rejects OAuth2Auth
-- explicitly with a named ProviderAuthenticationFailed rather than
-- attempting something unverified against this library's internals --
-- use an app password for Gmail IMAP in v1, per this codebase's own
-- recorded decision.
--
-- CONDSTORE/QRESYNC are not implemented -- no verified Haskell IMAP
-- library exposes them, and full UID-based resync (what this module
-- does) is correct and universally compatible without them. Treated as
-- a later optimization added with evidence it's needed (§26's own
-- explicit principle: "optimization requires evidence... not
-- intuition"), not a silently cut corner.
module Owl.Provider.IMAP
  ( connectImap
  , fetchDelta
  , translateFlag
  , discoverMailboxes
  , inferMailboxKind
  ) where

import Control.Exception (SomeException, try)
import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Network.HaskellNet.IMAP as IMAP
import qualified Network.HaskellNet.IMAP.Connection as HNConn
import qualified Network.HaskellNet.IMAP.SSL as IMAPSSL

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Owl.Application (MailboxKind (Inbox, DraftsMailbox, Trash, ArchiveMailbox, CustomMailbox), MailboxMeta (..))
import qualified Owl.Application as App
import Owl.Provider.IMAP.UTF7 (decodeMailboxUtf7)
import Owl.Domain.Flag (Flag (..))
import Owl.Domain.Id (MailboxId, mkMailboxId)
import Owl.Message.Identity (mkUID, mkUIDValidity, unUID, UIDValidity)
import Owl.Provider.Types

connectImap :: ProviderSettings -> Authentication -> IO (Either ProviderError ProviderSession)
connectImap settings auth = case auth of
  OAuth2Auth _ -> pure (Left (ProviderAuthenticationFailed
    "OAuth2 is not yet supported for IMAP login via HaskellNet (its IMAP AuthType has no XOAUTH2 constructor, unlike its SMTP AuthType) -- use an app password for now, per this codebase's own recorded decision"))
  PasswordAuth pw -> do
    result <- try $ do
      conn <- IMAPSSL.connectIMAPSSLWithSettings
        (Text.unpack (imapHost settings))
        IMAPSSL.defaultSettingsIMAPSSL
      IMAP.login conn (Text.unpack (providerUsername settings)) (Text.unpack pw)
      pure conn
    pure $ case result of
      Left (e :: SomeException) -> Left (ProviderConnectionFailed (Text.pack (show e)))
      Right conn                -> Right (ProviderSession settings auth conn)

fetchDelta :: SyncCursor -> ProviderSession -> IO (Either ProviderError RemoteDelta)
fetchDelta cursor session = do
  result <- try (runFetch cursor session) :: IO (Either SomeException (Either ProviderError RemoteDelta))
  pure (either (Left . ProviderConnectionFailed . Text.pack . show) id result)

runFetch :: SyncCursor -> ProviderSession -> IO (Either ProviderError RemoteDelta)
runFetch cursor session = do
  let conn   = sessionImapConn session
      folder = Text.unpack (cursorFolderName cursor)
  IMAP.select conn folder
  mValidity <- getUidValidity conn folder
  case mValidity of
    Nothing -> pure (Left (ProviderProtocolError "server did not report UIDVALIDITY for this mailbox"))
    Just freshValidity -> do
      hnUids <- IMAP.search conn [IMAP.ALLs]
      let lastUidRaw    = fromIntegral . unUID <$> cursorLastUid cursor
          resetHappened = maybe False (/= freshValidity) (cursorUidValidity cursor)
          knownHnUids   = if resetHappened then [] else maybe [] (\lastRaw -> filter (<= lastRaw) hnUids) lastUidRaw
          newHnUids     = if resetHappened then hnUids else filter (`notElem` knownHnUids) hnUids
      currentFlagsRaw <- traverse (\u -> (,) u <$> IMAP.fetchFlags conn u) knownHnUids
      newRawBytes     <- traverse (\u -> (,) u <$> IMAP.fetch conn u) newHnUids
      let allOwlUids   = mapMaybe (mkUID . fromIntegral) hnUids
          currentFlags = [ (owlUid, translateFlags hnFlags)
                          | (u, hnFlags) <- currentFlagsRaw, Just owlUid <- [mkUID (fromIntegral u)] ]
          newRaw       = [ (owlUid, bytes)
                          | (u, bytes) <- newRawBytes, Just owlUid <- [mkUID (fromIntegral u)] ]
      pure (Right (buildRemoteDelta cursor freshValidity allOwlUids currentFlags newRaw))

-- | CONFIDENCE: high -- status's shape is directly confirmed:
-- status :: IMAPConnection -> MailboxName -> [MailboxStatus] -> IO
-- [(MailboxStatus, Integer)], with UIDVALIDITY as one of
-- MailboxStatus's confirmed nullary constructors.
getUidValidity :: HNConn.IMAPConnection -> String -> IO (Maybe UIDValidity)
getUidValidity conn folder = do
  statuses <- IMAP.status conn folder [IMAP.UIDVALIDITY]
  pure (listToMaybe (mapMaybe toValidity statuses))
  where
    toValidity (IMAP.UIDVALIDITY, n) = mkUIDValidity (fromIntegral n)
    toValidity _                     = Nothing

translateFlags :: [IMAP.Flag] -> Set.Set Flag
translateFlags = Set.fromList . mapMaybe translateFlag

-- | Recent is session-scoped and never persisted (§10's own reasoning
-- for excluding it from Owl's Flag, applied here too); Keyword is a
-- custom/non-standard flag outside Owl's closed Flag set.
translateFlag :: IMAP.Flag -> Maybe Flag
translateFlag IMAP.Seen        = Just Seen
translateFlag IMAP.Answered    = Just Answered
translateFlag IMAP.Flagged     = Just Flagged
translateFlag IMAP.Deleted     = Just Deleted
translateFlag IMAP.Draft       = Just Draft
translateFlag IMAP.Recent      = Nothing
translateFlag (IMAP.Keyword _) = Nothing


-- | Mailbox discovery (fixing a real gap: MailboxState.mailboxCatalog
-- existed but nothing populated it). Uses HaskellNet's list, confirmed
-- directly against its source: list :: IMAPConnection -> IO
-- [([Attribute], MailboxName)].
--
-- inferMailboxKind is a name-based heuristic, not RFC 6154 SPECIAL-USE
-- attribute matching (\Sent, \Drafts, \Trash, \Archive, \Junk) --
-- HaskellNet's own Attribute type's exact constructors aren't verified
-- here, and guessing at them for a boundary this close to the network
-- is exactly the kind of thing this codebase has repeatedly chosen not
-- to do. Matching well-known folder names (including Gmail's actual
-- ones) is a safer, still-useful v1 approximation; a real
-- SPECIAL-USE-aware version is a natural follow-up once Attribute's
-- shape is confirmed.
discoverMailboxes :: ProviderSession -> IO (Either ProviderError (Map.Map MailboxId MailboxMeta))
discoverMailboxes session = do
  result <- try (IMAP.list (sessionImapConn session)) :: IO (Either SomeException [([IMAP.Attribute], String)])
  pure $ case result of
    Left e        -> Left (ProviderConnectionFailed (Text.pack (show e)))
    Right entries -> Right (Map.fromList (map toEntry entries))
  where
    acct = settingsAccountId (sessionSettings session)
    toEntry (_attrs, name) =
      let folderName = decodeMailboxUtf7 (Text.pack name)
      in ( mkMailboxId acct folderName
         , MailboxMeta { mailboxName = folderName, mailboxKind = inferMailboxKind folderName, mailboxParent = Nothing }
         )

inferMailboxKind :: Text -> MailboxKind
inferMailboxKind name
  | upper == "INBOX"                                                     = Inbox
  | name `elem` ["Sent", "Sent Items", "Sent Mail", "[Gmail]/Sent Mail"]  = App.Sent
  | name `elem` ["Drafts", "[Gmail]/Drafts"]                              = DraftsMailbox
  | name `elem` ["Trash", "Deleted Items", "Deleted Messages", "[Gmail]/Trash"] = Trash
  | name `elem` ["Archive", "All Mail", "[Gmail]/All Mail"]               = ArchiveMailbox
  | otherwise                                                             = CustomMailbox
  where
    upper = Text.toUpper name
