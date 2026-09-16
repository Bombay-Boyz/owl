-- | SQLite-backed StoreHandle (master spec §18). SQLite is the durable
-- canonical representation; derived indexes are rebuildable
-- materializations, not stored here.
--
-- searchMessages loads every stored message and every mail_membership
-- row, then delegates to the already-existing, already-tested search
-- engine (Owl.Search.Engine, §15/§17) rather than compiling Predicate
-- into SQL -- a full scan, same v1 simplification made elsewhere this
-- session, revisited only if benchmarks demand SQL-level narrowing.
--
-- Schema carries an explicit version (§18): v1 ships one version with
-- no migrations yet required, checked (not assumed) on every open.
module Owl.Store.SQLite
  ( openSQLiteStore
  , schemaVersion
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import qualified Data.UUID as UUID
import Database.SQLite.Simple hiding (Query)
import Database.SQLite.Simple.ToField (toField)

import Owl.Domain.Address (mkEmailAddress, unEmailAddress)
import Owl.Compose (Draft (..), Headers (..))
import Owl.Domain.Attachment (Attachment (..))
import Owl.Domain.Body (Body (..), sanitizeHtml, unSanitizedHtml)
import Owl.Domain.Flag (Flag (Seen, Answered, Flagged, Deleted))
import qualified Owl.Domain.Flag as Flag
import Owl.Domain.Identity (Identity (..))
import Data.Maybe (isNothing)
import Owl.Domain.Id (AccountId (..), LocalId (..), MailboxId (..), MessageId (..), ThreadId (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (mkSubject, unSubject)
import Owl.Message.Identity (MessageIdentity (..), parseRfcMessageId, unValidatedRfcId)
import Owl.Message.Types (Message (..))
import Owl.Search.Engine (buildSearchIndex, evaluate)
import Owl.Search.Predicate (MailMembership (..), Query)
import Owl.Store.Types

schemaVersion :: Int
schemaVersion = 1

openSQLiteStore :: FilePath -> IO (Either StoreError (StoreHandle IO))
openSQLiteStore path = do
  conn <- open path
  createSchema conn
  versionCheck <- checkSchemaVersion conn
  case versionCheck of
    Left err -> close conn >> pure (Left err)
    Right () -> pure (Right (sqliteStoreHandle conn))

createSchema :: Connection -> IO ()
createSchema conn = do
  execute_ conn "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)"
  countRows <- query_ conn "SELECT COUNT(*) FROM schema_version" :: IO [Only Int]
  case countRows of
    [Only 0] -> execute conn "INSERT INTO schema_version (version) VALUES (?)" (Only schemaVersion)
    _        -> pure ()
  execute_ conn
    "CREATE TABLE IF NOT EXISTS messages \
    \ ( message_id TEXT PRIMARY KEY \
    \ , account_id TEXT NOT NULL \
    \ , thread_id TEXT NOT NULL \
    \ , sender_name TEXT \
    \ , sender_email TEXT NOT NULL \
    \ , subject TEXT NOT NULL \
    \ , sent_at TEXT NOT NULL \
    \ , body_plain TEXT \
    \ , body_html TEXT \
    \ , rfc_account_id TEXT \
    \ , rfc_message_id TEXT \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS message_recipients \
    \ ( message_id TEXT NOT NULL \
    \ , ord INTEGER NOT NULL \
    \ , name TEXT \
    \ , email TEXT NOT NULL \
    \ , PRIMARY KEY (message_id, ord) \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS message_flags \
    \ ( message_id TEXT NOT NULL \
    \ , flag TEXT NOT NULL \
    \ , PRIMARY KEY (message_id, flag) \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS message_attachments \
    \ ( message_id TEXT NOT NULL \
    \ , ord INTEGER NOT NULL \
    \ , filename TEXT \
    \ , mime_type TEXT NOT NULL \
    \ , content BLOB NOT NULL \
    \ , PRIMARY KEY (message_id, ord) \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS message_references \
    \ ( message_id TEXT NOT NULL \
    \ , ord INTEGER NOT NULL \
    \ , rfc_id TEXT NOT NULL \
    \ , PRIMARY KEY (message_id, ord) \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS message_reply_to \
    \ ( message_id TEXT NOT NULL \
    \ , ord INTEGER NOT NULL \
    \ , name TEXT \
    \ , email TEXT NOT NULL \
    \ , PRIMARY KEY (message_id, ord) \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS mail_membership \
    \ ( message_id TEXT NOT NULL \
    \ , mailbox_id TEXT NOT NULL \
    \ , PRIMARY KEY (message_id, mailbox_id) \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS drafts \
    \ ( draft_id TEXT PRIMARY KEY \
    \ , identity_account_id TEXT NOT NULL \
    \ , identity_email TEXT NOT NULL \
    \ , identity_display_name TEXT \
    \ , identity_is_default INTEGER NOT NULL \
    \ , subject TEXT NOT NULL \
    \ , body_plain TEXT \
    \ , body_html TEXT \
    \ , thread_in_reply_to TEXT \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS draft_recipients \
    \ ( draft_id TEXT NOT NULL \
    \ , ord INTEGER NOT NULL \
    \ , name TEXT \
    \ , email TEXT NOT NULL \
    \ , PRIMARY KEY (draft_id, ord) \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS draft_attachments \
    \ ( draft_id TEXT NOT NULL \
    \ , ord INTEGER NOT NULL \
    \ , filename TEXT \
    \ , mime_type TEXT NOT NULL \
    \ , content BLOB NOT NULL \
    \ , PRIMARY KEY (draft_id, ord) \
    \ )"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS draft_references \
    \ ( draft_id TEXT NOT NULL \
    \ , ord INTEGER NOT NULL \
    \ , rfc_id TEXT NOT NULL \
    \ , PRIMARY KEY (draft_id, ord) \
    \ )"

checkSchemaVersion :: Connection -> IO (Either StoreError ())
checkSchemaVersion conn = do
  rows <- query_ conn "SELECT version FROM schema_version" :: IO [Only Int]
  pure $ case rows of
    [Only v] | v == schemaVersion -> Right ()
             | otherwise           -> Left (SchemaVersionMismatch schemaVersion (Just v))
    _                              -> Left (SchemaVersionMismatch schemaVersion Nothing)

sqliteStoreHandle :: Connection -> StoreHandle IO
sqliteStoreHandle conn = StoreHandle
  { loadMessage    = loadMessageImpl conn
  , saveMessage    = saveMessageImpl conn
  , searchMessages = searchMessagesImpl conn
  , loadDraft      = loadDraftImpl conn
  , saveDraft      = saveDraftImpl conn
  , deleteDraft    = deleteDraftImpl conn
  , listDrafts     = listDraftsImpl conn
  }

messageIdToText :: MessageId -> Text
messageIdToText (MessageId (LocalId uuid)) = UUID.toText uuid

textToMessageId :: Text -> Maybe MessageId
textToMessageId t = MessageId . LocalId <$> UUID.fromText t

flagToText :: Flag -> Text
flagToText Seen     = "Seen"
flagToText Answered = "Answered"
flagToText Flagged  = "Flagged"
flagToText Flag.Draft = "Draft"
flagToText Deleted  = "Deleted"

textToFlag :: Text -> Maybe Flag
textToFlag "Seen"     = Just Seen
textToFlag "Answered" = Just Answered
textToFlag "Flagged"  = Just Flagged
textToFlag "Draft"    = Just Flag.Draft
textToFlag "Deleted"  = Just Deleted
textToFlag _          = Nothing

unAccountId :: AccountId -> Text
unAccountId (AccountId t) = t

unThreadId :: ThreadId -> Text
unThreadId (ThreadId t) = t

data MessageRow = MessageRow
  { rowMessageId    :: Text
  , rowAccountId    :: Text
  , rowThreadId     :: Text
  , rowSenderName   :: Maybe Text
  , rowSenderEmail  :: Text
  , rowSubject      :: Text
  , rowSentAt       :: UTCTime
  , rowBodyPlain    :: Maybe Text
  , rowBodyHtml     :: Maybe Text
  , rowRfcAccountId :: Maybe Text
  , rowRfcMessageId :: Maybe Text
  }

instance ToRow MessageRow where
  toRow r =
    [ toField (rowMessageId r), toField (rowAccountId r), toField (rowThreadId r)
    , toField (rowSenderName r), toField (rowSenderEmail r), toField (rowSubject r)
    , toField (rowSentAt r), toField (rowBodyPlain r), toField (rowBodyHtml r)
    , toField (rowRfcAccountId r), toField (rowRfcMessageId r)
    ]

instance FromRow MessageRow where
  fromRow = MessageRow <$> field <*> field <*> field <*> field <*> field
                       <*> field <*> field <*> field <*> field <*> field <*> field

saveMessageImpl :: Connection -> Message -> IO (Either StoreError ())
saveMessageImpl conn msg = do
  result <- try (withTransaction conn (writeMessageRows conn msg)) :: IO (Either SomeException ())
  pure (either (Left . ConnectionError . Text.pack . show) Right result)

writeMessageRows :: Connection -> Message -> IO ()
writeMessageRows conn msg = do
  let mid     = messageId (identity msg)
      midText = messageIdToText mid
      row = MessageRow
        { rowMessageId    = midText
        , rowAccountId    = unAccountId (accountId msg)
        , rowThreadId     = unThreadId (threadId msg)
        , rowSenderName   = addressDisplayName (sender msg)
        , rowSenderEmail  = unEmailAddress (addressEmail (sender msg))
        , rowSubject      = unSubject (subject msg)
        , rowSentAt       = sentAt msg
        , rowBodyPlain    = bodyPlainText (body msg)
        , rowBodyHtml     = unSanitizedHtml <$> bodyHtml (body msg)
        , rowRfcAccountId = unAccountId . fst <$> rfcId (identity msg)
        , rowRfcMessageId = unValidatedRfcId . snd <$> rfcId (identity msg)
        }
  execute conn "DELETE FROM messages WHERE message_id = ?" (Only midText)
  execute conn "DELETE FROM message_recipients WHERE message_id = ?" (Only midText)
  execute conn "DELETE FROM message_flags WHERE message_id = ?" (Only midText)
  execute conn "DELETE FROM message_attachments WHERE message_id = ?" (Only midText)
  execute conn "DELETE FROM message_references WHERE message_id = ?" (Only midText)
  execute conn "DELETE FROM message_reply_to WHERE message_id = ?" (Only midText)
  execute conn
    "INSERT INTO messages (message_id, account_id, thread_id, sender_name, sender_email, subject, sent_at, body_plain, body_html, rfc_account_id, rfc_message_id) VALUES (?,?,?,?,?,?,?,?,?,?,?)"
    row
  mapM_ (\(i, addr) ->
           execute conn "INSERT INTO message_recipients (message_id, ord, name, email) VALUES (?,?,?,?)"
             (midText, i :: Int, addressDisplayName addr, unEmailAddress (addressEmail addr)))
        (zip [0 ..] (recipients msg))
  mapM_ (\flag -> execute conn "INSERT INTO message_flags (message_id, flag) VALUES (?,?)" (midText, flagToText flag))
        (Set.toList (flags msg))
  mapM_ (\(i, att) ->
           execute conn "INSERT INTO message_attachments (message_id, ord, filename, mime_type, content) VALUES (?,?,?,?,?)"
             (midText, i :: Int, attachmentFilename att, attachmentMimeType att, attachmentContent att))
        (zip [0 ..] (attachments msg))
  mapM_ (\(i, rid) ->
           execute conn "INSERT INTO message_references (message_id, ord, rfc_id) VALUES (?,?,?)"
             (midText, i :: Int, unValidatedRfcId rid))
        (zip [0 ..] (references msg))
  mapM_ (\(i, addr) ->
           execute conn "INSERT INTO message_reply_to (message_id, ord, name, email) VALUES (?,?,?,?)"
             (midText, i :: Int, addressDisplayName addr, unEmailAddress (addressEmail addr)))
        (zip [0 ..] (replyTo msg))

loadMessageImpl :: Connection -> MessageId -> IO (Either StoreError Message)
loadMessageImpl conn mid = do
  let midText = messageIdToText mid
  rows <- query conn
    "SELECT message_id, account_id, thread_id, sender_name, sender_email, subject, sent_at, body_plain, body_html, rfc_account_id, rfc_message_id FROM messages WHERE message_id = ?"
    (Only midText) :: IO [MessageRow]
  case rows of
    [] -> pure (Left (MessageNotFound mid))
    (row : _) -> do
      recipientRows  <- query conn "SELECT name, email FROM message_recipients WHERE message_id = ? ORDER BY ord" (Only midText) :: IO [(Maybe Text, Text)]
      flagRows       <- query conn "SELECT flag FROM message_flags WHERE message_id = ?" (Only midText) :: IO [Only Text]
      attachmentRows <- query conn "SELECT filename, mime_type, content FROM message_attachments WHERE message_id = ? ORDER BY ord" (Only midText) :: IO [(Maybe Text, Text, ByteString)]
      referenceRows  <- query conn "SELECT rfc_id FROM message_references WHERE message_id = ? ORDER BY ord" (Only midText) :: IO [Only Text]
      replyToRows    <- query conn "SELECT name, email FROM message_reply_to WHERE message_id = ? ORDER BY ord" (Only midText) :: IO [(Maybe Text, Text)]
      pure (reconstructMessage mid row recipientRows flagRows attachmentRows referenceRows replyToRows)

reconstructMessage
  :: MessageId
  -> MessageRow
  -> [(Maybe Text, Text)]
  -> [Only Text]
  -> [(Maybe Text, Text, ByteString)]
  -> [Only Text]
  -> [(Maybe Text, Text)]
  -> Either StoreError Message
reconstructMessage mid row recipientRows flagRows attachmentRows referenceRows replyToRows = do
  senderAddr     <- mkAddr (rowSenderName row) (rowSenderEmail row)
  recipientAddrs <- traverse (uncurry mkAddr) recipientRows
  replyToAddrs   <- traverse (uncurry mkAddr) replyToRows
  subj           <- either (const (Left (ConstraintViolation "invalid stored subject"))) Right (mkSubject (rowSubject row))
  flagsSet       <- Set.fromList <$> traverse decodeFlag flagRows
  refs           <- traverse decodeRef referenceRows
  rfcIdValue <- case (rowRfcAccountId row, rowRfcMessageId row) of
    (Just acctText, Just ridText) ->
      case parseRfcMessageId ridText of
        Just rid -> Right (Just (AccountId acctText, rid))
        Nothing  -> Left (ConstraintViolation ("invalid stored rfc message id: " <> ridText))
    _ -> Right Nothing
  pure Message
    { identity    = MessageIdentity { messageId = mid, rfcId = rfcIdValue }
    , accountId   = AccountId (rowAccountId row)
    , threadId    = ThreadId (rowThreadId row)
    , sender      = senderAddr
    , recipients  = recipientAddrs
    , subject     = subj
    , sentAt      = rowSentAt row
    , body        = Body (rowBodyPlain row) (sanitizeHtml <$> rowBodyHtml row)
    , attachments = map (\(fn, mt, c) -> Attachment fn mt c) attachmentRows
    , flags       = flagsSet
    , references  = refs
    , replyTo     = replyToAddrs
    }
  where
    mkAddr nm emailText = case mkEmailAddress emailText of
      Right e  -> Right (Address nm e)
      Left err -> Left (ConstraintViolation ("invalid stored email address: " <> Text.pack (show err)))
    decodeFlag (Only t) = maybe (Left (ConstraintViolation ("invalid stored flag: " <> t))) Right (textToFlag t)
    decodeRef (Only t) = maybe (Left (ConstraintViolation ("invalid stored rfc id: " <> t))) Right (parseRfcMessageId t)

searchMessagesImpl :: Connection -> Query -> IO (Either StoreError (Set MessageId))
searchMessagesImpl conn q = do
  allMidRows <- query_ conn "SELECT message_id FROM messages" :: IO [Only Text]
  let mids = mapMaybe (\(Only t) -> textToMessageId t) allMidRows
  loaded <- traverse (loadMessageImpl conn) mids
  case sequence loaded of
    Left err   -> pure (Left err)
    Right msgs -> do
      membershipRows <- query_ conn "SELECT message_id, mailbox_id FROM mail_membership" :: IO [(Text, Text)]
      let membership = MailMembership (Map.fromListWith Set.union
            [ (mid, Set.singleton (MailboxId mb))
            | (midT, mb) <- membershipRows
            , Just mid <- [textToMessageId midT]
            ])
          idx = buildSearchIndex membership msgs
      pure (Right (evaluate idx q))


-- | Draft persistence (fixing a real gap: DraftState previously lived
-- only in memory, so a draft was lost on app restart). Schema mirrors
-- messages' own child-table pattern (recipients/attachments in
-- separate tables, one row per item) minus the fields that only make
-- sense for a sent Message (flags, sentAt).

data DraftRow = DraftRow
  { rowDraftId             :: Text
  , rowIdentityAccountId   :: Text
  , rowIdentityEmail       :: Text
  , rowIdentityDisplayName :: Maybe Text
  , rowIdentityIsDefault   :: Int
  , rowDraftSubject        :: Text
  , rowDraftBodyPlain      :: Maybe Text
  , rowDraftBodyHtml       :: Maybe Text
  , rowThreadInReplyTo     :: Maybe Text
  }

instance ToRow DraftRow where
  toRow r =
    [ toField (rowDraftId r), toField (rowIdentityAccountId r), toField (rowIdentityEmail r)
    , toField (rowIdentityDisplayName r), toField (rowIdentityIsDefault r), toField (rowDraftSubject r)
    , toField (rowDraftBodyPlain r), toField (rowDraftBodyHtml r), toField (rowThreadInReplyTo r)
    ]

instance FromRow DraftRow where
  fromRow = DraftRow <$> field <*> field <*> field <*> field <*> field
                     <*> field <*> field <*> field <*> field

saveDraftImpl :: Connection -> Draft -> IO (Either StoreError ())
saveDraftImpl conn draft = do
  result <- try (withTransaction conn (writeDraftRows conn draft)) :: IO (Either SomeException ())
  pure (either (Left . ConnectionError . Text.pack . show) Right result)

writeDraftRows :: Connection -> Draft -> IO ()
writeDraftRows conn draft = do
  let did   = messageIdToText (draftId draft)
      ident = draftIdentity draft
      row = DraftRow
        { rowDraftId             = did
        , rowIdentityAccountId   = unAccountId (identityAccountId ident)
        , rowIdentityEmail       = unEmailAddress (identityEmailAddress ident)
        , rowIdentityDisplayName = identityDisplayName ident
        , rowIdentityIsDefault   = if identityIsDefault ident then 1 else 0
        , rowDraftSubject        = unSubject (draftSubject draft)
        , rowDraftBodyPlain      = bodyPlainText (draftBody draft)
        , rowDraftBodyHtml       = unSanitizedHtml <$> bodyHtml (draftBody draft)
        , rowThreadInReplyTo     = unValidatedRfcId <$> (draftThreadHeaders draft >>= headersInReplyTo)
        }
  execute conn "DELETE FROM drafts WHERE draft_id = ?" (Only did)
  execute conn "DELETE FROM draft_recipients WHERE draft_id = ?" (Only did)
  execute conn "DELETE FROM draft_attachments WHERE draft_id = ?" (Only did)
  execute conn "DELETE FROM draft_references WHERE draft_id = ?" (Only did)
  execute conn
    "INSERT INTO drafts (draft_id, identity_account_id, identity_email, identity_display_name, identity_is_default, subject, body_plain, body_html, thread_in_reply_to) VALUES (?,?,?,?,?,?,?,?,?)"
    row
  mapM_ (\(i, addr) ->
           execute conn "INSERT INTO draft_recipients (draft_id, ord, name, email) VALUES (?,?,?,?)"
             (did, i :: Int, addressDisplayName addr, unEmailAddress (addressEmail addr)))
        (zip [0 ..] (draftRecipients draft))
  mapM_ (\(i, att) ->
           execute conn "INSERT INTO draft_attachments (draft_id, ord, filename, mime_type, content) VALUES (?,?,?,?,?)"
             (did, i :: Int, attachmentFilename att, attachmentMimeType att, attachmentContent att))
        (zip [0 ..] (draftAttachments draft))
  mapM_ (\(i, rid) ->
           execute conn "INSERT INTO draft_references (draft_id, ord, rfc_id) VALUES (?,?,?)"
             (did, i :: Int, unValidatedRfcId rid))
        (zip [0 ..] (maybe [] headersReferences (draftThreadHeaders draft)))

loadDraftImpl :: Connection -> MessageId -> IO (Either StoreError Draft)
loadDraftImpl conn mid = do
  let did = messageIdToText mid
  rows <- query conn
    "SELECT draft_id, identity_account_id, identity_email, identity_display_name, identity_is_default, subject, body_plain, body_html, thread_in_reply_to FROM drafts WHERE draft_id = ?"
    (Only did) :: IO [DraftRow]
  case rows of
    [] -> pure (Left (DraftNotFound mid))
    (row : _) -> do
      recipientRows  <- query conn "SELECT name, email FROM draft_recipients WHERE draft_id = ? ORDER BY ord" (Only did) :: IO [(Maybe Text, Text)]
      attachmentRows <- query conn "SELECT filename, mime_type, content FROM draft_attachments WHERE draft_id = ? ORDER BY ord" (Only did) :: IO [(Maybe Text, Text, ByteString)]
      referenceRows  <- query conn "SELECT rfc_id FROM draft_references WHERE draft_id = ? ORDER BY ord" (Only did) :: IO [Only Text]
      pure (reconstructDraft mid row recipientRows attachmentRows referenceRows)

reconstructDraft
  :: MessageId
  -> DraftRow
  -> [(Maybe Text, Text)]
  -> [(Maybe Text, Text, ByteString)]
  -> [Only Text]
  -> Either StoreError Draft
reconstructDraft mid row recipientRows attachmentRows referenceRows = do
  identityEmail  <- either (const (Left (ConstraintViolation "invalid stored identity email"))) Right (mkEmailAddress (rowIdentityEmail row))
  recipientAddrs <- traverse (uncurry mkAddr) recipientRows
  subj           <- either (const (Left (ConstraintViolation "invalid stored draft subject"))) Right (mkSubject (rowDraftSubject row))
  refs           <- traverse decodeRef referenceRows
  inReplyToRid   <- traverse decodeRfc (rowThreadInReplyTo row)
  pure Draft
    { draftId            = mid
    , draftIdentity      = Identity
        { identityAccountId    = AccountId (rowIdentityAccountId row)
        , identityEmailAddress = identityEmail
        , identityDisplayName  = rowIdentityDisplayName row
        , identityIsDefault    = rowIdentityIsDefault row /= 0
        }
    , draftRecipients    = recipientAddrs
    , draftSubject       = subj
    , draftBody          = Body (rowDraftBodyPlain row) (sanitizeHtml <$> rowDraftBodyHtml row)
    , draftAttachments   = map (\(fn, mt, c) -> Attachment fn mt c) attachmentRows
    , draftThreadHeaders = if null refs && isNothing inReplyToRid then Nothing else Just (Headers inReplyToRid refs)
    }
  where
    mkAddr nm emailText = case mkEmailAddress emailText of
      Right e  -> Right (Address nm e)
      Left err -> Left (ConstraintViolation ("invalid stored draft recipient address: " <> Text.pack (show err)))
    decodeRef (Only t) = maybe (Left (ConstraintViolation ("invalid stored draft reference: " <> t))) Right (parseRfcMessageId t)
    decodeRfc t         = maybe (Left (ConstraintViolation ("invalid stored draft in-reply-to: " <> t))) Right (parseRfcMessageId t)

deleteDraftImpl :: Connection -> MessageId -> IO (Either StoreError ())
deleteDraftImpl conn mid = do
  result <- try (withTransaction conn (deleteDraftRows conn (messageIdToText mid))) :: IO (Either SomeException ())
  pure (either (Left . ConnectionError . Text.pack . show) Right result)

deleteDraftRows :: Connection -> Text -> IO ()
deleteDraftRows conn did = do
  execute conn "DELETE FROM drafts WHERE draft_id = ?" (Only did)
  execute conn "DELETE FROM draft_recipients WHERE draft_id = ?" (Only did)
  execute conn "DELETE FROM draft_attachments WHERE draft_id = ?" (Only did)
  execute conn "DELETE FROM draft_references WHERE draft_id = ?" (Only did)

listDraftsImpl :: Connection -> IO (Either StoreError [MessageId])
listDraftsImpl conn = do
  rows <- query_ conn "SELECT draft_id FROM drafts" :: IO [Only Text]
  pure (Right (mapMaybe (\(Only t) -> textToMessageId t) rows))
