module Owl.Message.Types
  ( Message (..)
  ) where

import Data.Set (Set)
import Data.Time (UTCTime)

import Owl.Domain.Attachment (Attachment)
import Owl.Domain.Body (Body)
import Owl.Domain.Flag (Flag)
import Owl.Domain.Id (AccountId, ThreadId)
import Owl.Domain.MailAddress (Address)
import Owl.Domain.Subject (Subject)
import Owl.Message.Identity (MessageIdentity, ValidatedRfcId)

-- | The trusted, validated domain representation of an email (§12).
-- recipients is a plain list, not NonEmpty -- a received message can
-- legitimately have zero visible recipients (a Bcc-only delivery has no
-- To/Cc at all by the time Owl sees it). NonEmpty becomes the correct
-- constraint only at OutgoingEnvelope (§21), where zero RCPT TO
-- recipients really is meaningless.
data Message = Message
  { identity    :: !MessageIdentity
  , accountId   :: !AccountId
  , threadId    :: !ThreadId
  , sender      :: !Address
  , recipients  :: ![Address]
  , subject     :: !Subject
  , sentAt      :: !UTCTime
  , body        :: !Body
  , attachments :: ![Attachment]
  , flags       :: !(Set Flag)
  , references  :: ![ValidatedRfcId]
    -- ^ Not in the master spec's original §12 Message record -- added
    -- because §14's messageReferences :: Message -> [ValidatedRfcId]
    -- has no data to read otherwise. Justified under §11's own rule:
    -- "an already-shipped feature requires it" -- threading is
    -- explicit v1 scope (§2) and cannot function without this.
  , replyTo     :: ![Address]
    -- ^ Also not in the original §12 record -- added because §21's
    -- "Reply-To precedence" is an explicit test requirement, and
    -- nothing else on Message carries a Reply-To address. Same
    -- justification pattern as references, above.
  }
  deriving stock (Eq, Show)
