-- | Shared boolean predicate core (master spec §15): the vocabulary of
-- "what does a message match," used identically by search (this
-- module) and rule matching (§22) -- one type, one evaluator.
--
-- matches takes MailMembership as an explicit, minimal, documented
-- parameter beyond the master spec's literal one-line signature
-- (`Message -> Predicate -> Bool`) -- §15's own text is explicit that
-- InMailbox "matches against the MailMembership relation (§11), not a
-- single field on Message," so a bare Message genuinely cannot answer
-- it; this is implementing exactly what the prose already says, not a
-- silent deviation.
module Owl.Search.Predicate
  ( Predicate (..)
  , Query
  , Phrase (..)
  , MailMembership (..)
  , addMembership
  , removeMembership
  , matches
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (Day, utctDay)
import Data.List.NonEmpty (NonEmpty)

import Owl.Domain.Address (EmailAddress)
import Owl.Domain.Body (bodyPlainText)
import Owl.Domain.Flag (Flag (Seen))
import Owl.Domain.Id (MailboxId, MessageId, ThreadId)
import Owl.Domain.MailAddress (Address (addressEmail))
import Owl.Domain.Subject (unSubject)
import Owl.Message.Identity (MessageIdentity (messageId))
import Owl.Message.Types (Message (..))

-- | An exact multi-word phrase (from a quoted query string, e.g.
-- "annual report") -- distinct from a bare Term (§15): matches checks
-- it as an exact substring in the body text, never per-word.
newtype Phrase = Phrase Text
  deriving stock (Show)
  deriving newtype (Eq, Ord)

data Predicate
  = From EmailAddress
  | To EmailAddress
  | SubjectContains Text
  | Body Phrase
  | HasAttachment
  | IsUnread
  | InMailbox MailboxId
  | InThread ThreadId
  | After Day
  | Before Day
  | And (NonEmpty Predicate)
  | Or (NonEmpty Predicate)
  | Not Predicate
  deriving stock (Eq, Show)

-- | A search query is exactly a Predicate. Kept as a distinct name at
-- call sites for readability; no separate constructor set to maintain.
type Query = Predicate

-- | §11/§17: message-to-mailbox membership, multi-valued -- a message
-- can be In('Inbox') AND In('Work') at once.
newtype MailMembership = MailMembership (Map MessageId (Set MailboxId))
  deriving stock (Eq, Show)

matches :: MailMembership -> Message -> Predicate -> Bool
matches membership msg predicate = case predicate of
  From addr           -> addressEmail (sender msg) == addr
  To addr             -> any ((== addr) . addressEmail) (recipients msg)
  SubjectContains q   -> Text.toCaseFold q `Text.isInfixOf` Text.toCaseFold (unSubject (subject msg))
  Body (Phrase p)     -> maybe False (Text.isInfixOf (Text.toCaseFold p) . Text.toCaseFold) (bodyPlainText (body msg))
  HasAttachment       -> not (null (attachments msg))
  IsUnread            -> not (Set.member Seen (flags msg))
  InMailbox mid       -> Set.member mid (memberMailboxes membership (messageId (identity msg)))
  InThread tid        -> threadId msg == tid
  After day           -> utctDay (sentAt msg) > day
  Before day          -> utctDay (sentAt msg) < day
  And ps              -> all (matches membership msg) ps
  Or ps               -> any (matches membership msg) ps
  Not p               -> not (matches membership msg p)

memberMailboxes :: MailMembership -> MessageId -> Set MailboxId
memberMailboxes (MailMembership m) mid = Map.findWithDefault Set.empty mid m

-- | Incremental maintenance for MailMembership (§17): each of
-- MessageMoved/MessageLabeled/MessageUnlabeled touches exactly one or
-- two entries, never a whole-relation rebuild.
addMembership :: MessageId -> MailboxId -> MailMembership -> MailMembership
addMembership mid mbox (MailMembership m) = MailMembership (Map.insertWith Set.union mid (Set.singleton mbox) m)

removeMembership :: MessageId -> MailboxId -> MailMembership -> MailMembership
removeMembership mid mbox (MailMembership m) = MailMembership (Map.adjust (Set.delete mbox) mid m)
