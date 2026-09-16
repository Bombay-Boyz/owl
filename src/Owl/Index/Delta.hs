-- | Derived indexes (master spec §17): search and thread indexes are
-- derived materializations over canonical Application state, never
-- independent sources of truth. Each Event produces a small, explicit
-- IndexDelta, derived structurally from its own constructor --
-- incrementality is enforced by the type of the update function, not a
-- hoped-for optimization applied later.
module Owl.Index.Delta
  ( SearchIndexDelta (..)
  , ThreadIndexDelta (..)
  , IndexDelta (..)
  , ThreadIndex (..)
  , emptyThreadIndex
  , deltaFor
  , applySearchIndexDelta
  , applyThreadIndexDelta
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Time (utctDay)

import Data.Text (Text)
import Owl.Domain.Address (unEmailAddress)
import Owl.Domain.Id (MailboxId, MessageId, ThreadId)
import Owl.Domain.MailAddress (Address, addressEmail)
import Owl.Event (Event (..))
import Owl.Message.Identity (MessageIdentity (messageId))
import Owl.Message.Types (Message (..))
import Owl.Search.Engine (SearchIndex (..))
import qualified Owl.Search.Index as Index
import Owl.Search.Predicate (addMembership, removeMembership)

-- | MessageReceived's payload carries no mailbox (§12's Message record
-- has none) -- so this delta only ever touches term postings and
-- DocumentStatistics, never mailbox membership; initial mailbox
-- placement happens via a separate MessageLabeled/MessageMoved event.
data SearchIndexDelta
  = IndexNewMessage Message
  | IndexMembershipChange MessageId (Set MailboxId) (Set MailboxId)  -- (added, removed)
  deriving stock (Eq, Show)

-- | A cache of an already-decided threadId (assigned by
-- Owl.Thread.threadMessages or singletonThreadId upstream), not a
-- re-derivation of JWZ threading -- this module never decides which
-- thread a message belongs to, only records it.
data ThreadIndexDelta = ThreadIndexDelta
  { threadDeltaThreadId :: !ThreadId
  , threadDeltaMessage  :: !Message
  }
  deriving stock (Eq, Show)

data IndexDelta = IndexDelta
  { searchDelta :: !(Maybe SearchIndexDelta)
  , threadDelta :: !(Maybe ThreadIndexDelta)
  }
  deriving stock (Eq, Show)

newtype ThreadIndex = ThreadIndex (Map ThreadId (Map MessageId Message))
  deriving stock (Eq, Show)

emptyThreadIndex :: ThreadIndex
emptyThreadIndex = ThreadIndex Map.empty

-- | Derived structurally from the event's own constructor (§17) -- one
-- case per Event constructor, exhaustive under -Wincomplete-patterns.
deltaFor :: Event -> IndexDelta
deltaFor event = case event of
  MessageReceived msg ->
    IndexDelta (Just (IndexNewMessage msg)) (Just (ThreadIndexDelta (threadId msg) msg))
  MessageRead _             -> IndexDelta Nothing Nothing
  MessageUnread _           -> IndexDelta Nothing Nothing
  MessageArchived _         -> IndexDelta Nothing Nothing
  MessageUnarchived _       -> IndexDelta Nothing Nothing
  MessageDeleted _          -> IndexDelta Nothing Nothing
  MessageRestored _         -> IndexDelta Nothing Nothing
  MessageMoved mid src dst  -> IndexDelta (Just (IndexMembershipChange mid (Set.singleton dst) (Set.singleton src))) Nothing
  MessageLabeled mid mbox   -> IndexDelta (Just (IndexMembershipChange mid (Set.singleton mbox) Set.empty)) Nothing
  MessageUnlabeled mid mbox -> IndexDelta (Just (IndexMembershipChange mid Set.empty (Set.singleton mbox))) Nothing
  DraftCreated _            -> IndexDelta Nothing Nothing
  DraftChanged _            -> IndexDelta Nothing Nothing
  -- MessageSent's own payload is a bare MessageId -- no Message content
  -- to index from the event alone. Indexing a newly-sent message's
  -- content is the send pipeline's job (it already has the real
  -- Message value at hand when it fires this event); deltaFor cannot
  -- derive it structurally from MessageSent's constructor by itself.
  -- A stated scope limit, not a silent gap.
  MessageSent _             -> IndexDelta Nothing Nothing
  -- AddressBook's own ContactIndex (§16) is a separate structure;
  -- IndexDelta is scoped to exactly the two indexes §17 names (search,
  -- thread).
  ContactChanged _          -> IndexDelta Nothing Nothing

applySearchIndexDelta :: SearchIndexDelta -> SearchIndex -> SearchIndex
applySearchIndexDelta delta idx = case delta of
  IndexNewMessage msg -> idx
    { siMessages    = Map.insert mid msg (siMessages idx)
    , siBySender    = Map.insertWith Set.union (addrKey (sender msg)) (Set.singleton mid) (siBySender idx)
    , siByRecipient = foldr (\r m -> Map.insertWith Set.union (addrKey r) (Set.singleton mid) m) (siByRecipient idx) (recipients msg)
    , siByThread    = Map.insertWith Set.union (threadId msg) (Set.singleton mid) (siByThread idx)
    , siByDay       = Map.insertWith Set.union (utctDay (sentAt msg)) (Set.singleton mid) (siByDay idx)
    , siInverted    = Index.insertMessage msg (siInverted idx)
    , siStats       = Index.insertMessageStats msg (siStats idx)
    }
    where mid = messageId (identity msg)
  IndexMembershipChange mid added removed -> idx
    { siMembership = foldr (removeMembership mid) (foldr (addMembership mid) (siMembership idx) (Set.toList added)) (Set.toList removed)
    , siByMailbox  =
        let withRemovals = foldr (Map.adjust (Set.delete mid)) (siByMailbox idx) (Set.toList removed)
        in foldr (\mb m -> Map.insertWith Set.union mb (Set.singleton mid) m) withRemovals (Set.toList added)
    }

addrKey :: Address -> Text
addrKey a = Text.toCaseFold (unEmailAddress (addressEmail a))

applyThreadIndexDelta :: ThreadIndexDelta -> ThreadIndex -> ThreadIndex
applyThreadIndexDelta (ThreadIndexDelta tid msg) (ThreadIndex m) =
  ThreadIndex (Map.insertWith Map.union tid (Map.singleton (messageId (identity msg)) msg) m)
