-- | Provider adapters and protocols as boundaries (master spec §20).
-- Owl's sync model must not become an IMAP model: SyncCursor and
-- RemoteDelta are Owl-shaped, not IMAP-shaped, even though IMAP is the
-- only thing that produces them right now. JMAP is explicitly not a
-- v1 requirement -- no generalized provider typeclass is built here;
-- a second real implementation would need to exist, with observed
-- duplication, before generalizing.
--
-- RemoteDelta deliberately has no "vanished messages" field. Detecting
-- a message that disappeared server-side is already §19's reconciler's
-- job: comparing an old LocalSnapshot against a fresh RemoteSnapshot
-- (built from this delta's own new/updated entries) naturally surfaces
-- "known locally, absent remotely" as RemoteDeleted via
-- toReconciliationInput's own existing case. An earlier draft of this
-- module tried to compute vanished-ness here too, using only a single
-- high-water-mark UID (cursorLastUid) rather than the full previously-
-- known UID set -- that computation was structurally incapable of ever
-- firing (the "known" side was already filtered to UIDs still present,
-- by construction) and was removed rather than patched, since the
-- correct logic already exists one layer up.
--
-- buildRemoteDelta is the pure core this whole module exists to
-- protect: given already-fetched raw IMAP facts (no IO), it decides
-- what changed. Owl.Provider.IMAP's fetchDelta is the thin, less-
-- testable IO shell that gathers those facts -- the same boundary
-- discipline used at the message boundary (§12) and the reconciler
-- (§19), applied to the piece of this codebase closest to the network.
module Owl.Provider.Types
  ( Authentication (..)
  , ProviderSettings (..)
  , ProviderSession (..)
  , SyncCursor (..)
  , RemoteDelta (..)
  , ProviderError (..)
  , SendOutcome (..)
  , buildRemoteDelta
  ) where

import Data.ByteString (ByteString)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Network.HaskellNet.IMAP.Connection as HNConn

import Owl.Domain.Flag (Flag)
import Owl.Domain.Id (AccountId, MailboxId)
import Owl.Message.Identity (RemoteRef (..), UID, UIDValidity)
import Owl.Sync.Types (RemoteObservation (..))

-- | The current credential to present -- refresh (if OAuth2) is a
-- separate concern (§27's RefreshGuard), not this type's job.
--
-- Show is hand-written, not derived: a derived instance would print
-- the raw password/token verbatim, meaning a stray `show`/debug print
-- anywhere in the codebase (or an uncaught exception embedding a Show
-- of some containing structure) could leak a live credential into
-- logs or terminal output. A real, currently-existing risk caught and
-- fixed during a hardening pass, not a hypothetical one.
data Authentication
  = PasswordAuth Text  -- plain or app-specific password
  | OAuth2Auth Text    -- a currently-valid access token (bearer)
  deriving stock (Eq)

instance Show Authentication where
  show (PasswordAuth _) = "PasswordAuth <redacted>"
  show (OAuth2Auth _)   = "OAuth2Auth <redacted>"

-- | settingsAccountId is a necessary addition beyond an earlier draft
-- of this type: mailbox discovery (Owl.Provider.IMAP.discoverMailboxes)
-- needs to mint MailboxId values via mkMailboxId, which requires the
-- owning AccountId -- §10's own rule that a MailboxId must never be
-- derived from a raw folder name alone.
data ProviderSettings = ProviderSettings
  { settingsAccountId :: !AccountId
  , imapHost          :: !Text
  , imapPort          :: !Int
  , smtpHost          :: !Text
  , smtpPort          :: !Int
  , providerUsername  :: !Text  -- the login identity, typically the email address
  }
  deriving stock (Eq, Show)

-- | Deliberately not Eq/Show -- it carries a live, mutable IMAP
-- connection, the same class of effectful Handle as
-- Owl.Store.Types.StoreHandle, which doesn't derive them either.
data ProviderSession = ProviderSession
  { sessionSettings :: !ProviderSettings
  , sessionAuth     :: !Authentication
  , sessionImapConn :: !HNConn.IMAPConnection
  }

-- | SyncCursor carries the raw provider-side folder name directly
-- (cursorFolderName), not just Owl's own MailboxId -- fetchDelta's
-- given signature has no parameter for a mailbox-catalog lookup, and
-- SyncCursor is entirely Owl's own type (never given a concrete shape
-- by §20), so it is free to carry the concrete resumption coordinates
-- actually needed to resume, exactly as RemoteRef already carries
-- MailboxId+UIDValidity+UID for a single message (§13).
data SyncCursor = SyncCursor
  { cursorMailboxId   :: !MailboxId
  , cursorFolderName  :: !Text
  , cursorUidValidity :: !(Maybe UIDValidity)  -- Nothing on the very first sync of this mailbox
  , cursorLastUid     :: !(Maybe UID)          -- Nothing on the very first sync of this mailbox
  }
  deriving stock (Eq, Show)

data RemoteDelta = RemoteDelta
  { deltaCursor           :: !SyncCursor         -- the new cursor to persist for next time
  , deltaNewMessages      :: ![(RemoteRef, ByteString)]
  , deltaUpdatedFlags     :: ![RemoteObservation]
  , deltaUidValidityReset :: !Bool
  }
  deriving stock (Eq, Show)

data ProviderError
  = ProviderConnectionFailed Text
  | ProviderAuthenticationFailed Text
  | ProviderProtocolError Text
  | ProviderTimeout
  deriving stock (Eq, Show)

-- | A connection lost after the SMTP payload was handed off is not the
-- same as a clean rejection -- the message may have been accepted.
-- That ambiguity is represented explicitly (§20), the same way §19
-- represents sync ambiguity, rather than collapsed into a plain
-- failure that would invite a blind (possibly duplicate) retry.
data SendOutcome = Sent | SendOutcomeUnknown
  deriving stock (Eq, Show)

-- | The pure decision core: given a fresh UIDVALIDITY, every UID
-- currently in the mailbox (used only to advance the cursor's high-
-- water mark), flags for previously-known messages, and raw bytes for
-- genuinely new ones, decide what the RemoteDelta is. No IO, no
-- network -- unit-testable with hand-constructed inputs.
--
-- A UIDVALIDITY change relative to the cursor is reported via
-- deltaUidValidityReset so the caller knows every old RemoteRef in
-- this mailbox is now a meaningless coordinate under the new epoch
-- (§13) -- it does not itself decide what to do about that; §19's
-- reconciler and the re-derivation-by-Message-ID strategy (§20) are
-- what actually handle a reset.
buildRemoteDelta
  :: SyncCursor
  -> UIDValidity
  -> [UID]
  -> [(UID, Set Flag)]
  -> [(UID, ByteString)]
  -> RemoteDelta
buildRemoteDelta cursor freshValidity allCurrentUids currentFlags newRaw =
  RemoteDelta
    { deltaCursor           = cursor
        { cursorUidValidity = Just freshValidity
        , cursorLastUid     = maxUid allCurrentUids (cursorLastUid cursor)
        }
    , deltaNewMessages      = [ (mkRef uid, bytes) | (uid, bytes) <- newRaw ]
    , deltaUpdatedFlags     = [ RemoteObservation (mkRef uid) flags | (uid, flags) <- currentFlags ]
    , deltaUidValidityReset = resetHappened
    }
  where
    resetHappened = maybe False (/= freshValidity) (cursorUidValidity cursor)
    mkRef uid = ImapRef (cursorMailboxId cursor) freshValidity uid
    maxUid uids prior = case Set.lookupMax (Set.fromList uids) of
      Just m  -> Just m
      Nothing -> prior
