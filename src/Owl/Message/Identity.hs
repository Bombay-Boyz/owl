-- | Message identity vocabulary (master spec §13).
module Owl.Message.Identity
  ( ValidatedRfcId
  , unValidatedRfcId
  , parseRfcMessageId
  , MessageIdentity (..)
  , RemoteRef (..)
  , UID
  , mkUID
  , unUID
  , UIDValidity
  , mkUIDValidity
  , unUIDValidity
  , singletonThreadId
  ) where

import Data.Text (Text)
import Data.Word (Word32)
import qualified Data.Text as Text
import qualified Data.UUID as UUID

import Owl.Domain.Id (AccountId, LocalId (..), MailboxId, MessageId (..), ThreadId (..))

-- | An RFC 5322 Message-ID that has passed validation (§13). Only
-- constructible via parseRfcMessageId -- a value of this type is a
-- guarantee, not a hope.
--
-- Validation here is a narrower, hand-rolled subset of RFC 5322 §3.6.4's
-- msg-id grammar (angle brackets, a mandatory internal '@', no
-- whitespace/control characters) -- the same staged, best-effort-now /
-- mature-library-later posture as Owl.Domain.Address's
-- mkEmailAddress, superseded once the message boundary's real MIME
-- parser (§12) extracts Message-ID values itself.
newtype ValidatedRfcId = ValidatedRfcId Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

unValidatedRfcId :: ValidatedRfcId -> Text
unValidatedRfcId (ValidatedRfcId t) = t

parseRfcMessageId :: Text -> Maybe ValidatedRfcId
parseRfcMessageId raw
  | Text.length raw < 5                          = Nothing  -- shortest possible: "<a@b>"
  | Text.head raw /= '<' || Text.last raw /= '>'  = Nothing
  | Text.any isControlOrSpace inner               = Nothing
  | not (Text.elem '@' inner)                     = Nothing
  | Text.null idLeft || Text.null idRight         = Nothing
  | otherwise                                     = Just (ValidatedRfcId raw)
  where
    inner            = Text.init (Text.tail raw)
    (idLeft, rest)   = Text.breakOn "@" inner
    idRight          = Text.drop 1 rest
    isControlOrSpace c = c == ' ' || c < ' '

-- | Owl's own identity (§10) as the primary key, plus a secondary
-- heuristic index scoped per account (§13) -- never global, since two
-- different accounts can legitimately observe colliding Message-ID
-- headers.
data MessageIdentity = MessageIdentity
  { messageId :: !MessageId
  , rfcId     :: !(Maybe (AccountId, ValidatedRfcId))
  }
  deriving stock (Eq, Show)

-- | RFC 9051 §2.3.1.1: both UID and UIDVALIDITY are 32-bit, non-zero
-- values ("nz-number" in the IMAP ABNF) -- given a real representation
-- now that §19 (Synchronization as Reconciliation) is the first phase
-- that actually needs to construct and compare these, rather than
-- staying the Phase 2 placeholder (a zero-constructor stub deferred to
-- "Phase 8's IMAP adapter"). No constructor is exported bare -- mkUID/
-- mkUIDValidity are the only way to build one, matching every other
-- validated newtype in this codebase.
newtype UID = UID Word32
  deriving stock (Show)
  deriving newtype (Eq, Ord)

newtype UIDValidity = UIDValidity Word32
  deriving stock (Show)
  deriving newtype (Eq, Ord)

mkUID :: Word32 -> Maybe UID
mkUID 0 = Nothing
mkUID n = Just (UID n)

unUID :: UID -> Word32
unUID (UID n) = n

mkUIDValidity :: Word32 -> Maybe UIDValidity
mkUIDValidity 0 = Nothing
mkUIDValidity n = Just (UIDValidity n)

unUIDValidity :: UIDValidity -> Word32
unUIDValidity (UIDValidity n) = n

-- | A remote identifier is an observation about a message, valid only
-- alongside the UIDVALIDITY epoch it was observed under (§13). A
-- UIDVALIDITY change invalidates every ImapRef scoped to it -- the
-- reconciler (§19) treats this as "no known remote refs for this
-- mailbox," not as an error.
data RemoteRef = ImapRef !MailboxId !UIDValidity !UID
  deriving stock (Eq, Show)

-- | Every message starts as a singleton thread of itself -- a
-- genuinely valid ThreadId under §14's model (a thread with exactly
-- one message is a perfectly normal state), not a placeholder standing
-- in for a value that doesn't exist yet. §14's threadMessages later
-- merges singleton threads into shared threads as it discovers real
-- Message-ID/In-Reply-To/References relationships. This is what lets
-- the message boundary (§12) mint a complete, valid Message without
-- needing threading to have run first, and without toMessage needing
-- any signature deviation at all.
singletonThreadId :: MessageId -> ThreadId
singletonThreadId (MessageId (LocalId uuid)) = ThreadId (UUID.toText uuid)
