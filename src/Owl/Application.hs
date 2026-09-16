-- | State composition (master spec §11): no monolithic state type --
-- each space is its own type, composed explicitly.
--
-- MessageState carries archivedMessages/deletedMessages as their own
-- Set MessageId relations, mirroring MailMembership's own design,
-- rather than repurposing Flag's Deleted constructor (documented in
-- Owl.Domain.Flag as provider-interop only, never set by Owl's own
-- domain model) or adding new fields to the already-stable Message
-- record.
--
-- ThreadState and MailboxState.membership are canonical relations, not
-- derived indexes -- §17 is explicit that indexes are derived FROM
-- Application, never part of it, so ThreadState is a plain
-- Map ThreadId (Set MessageId), not the ThreadForest/ThreadIndex
-- structures Owl.Thread/Owl.Index.Delta already compute at runtime.
module Owl.Application
  ( MessageState (..)
  , ThreadState (..)
  , ContactState (..)
  , MailboxKind (..)
  , MailboxMeta (..)
  , MailboxState (..)
  , DraftState (..)
  , Application (..)
  , emptyApplication
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)

import Owl.AddressBook (AddressBook, mkAddressBook)
import Owl.Domain.Id (AccountId, MailboxId, MessageId, ThreadId)
import Owl.Compose (Draft)
import Owl.Message.Types (Message)
import Owl.Search.Predicate (MailMembership (..))
import Owl.Sync.Types (SyncState (..))

data MessageState = MessageState
  { messageStateMessages :: !(Map MessageId Message)
  , archivedMessages     :: !(Set MessageId)
  , deletedMessages      :: !(Set MessageId)  -- soft delete (§24: "Delete is soft")
  }
  deriving stock (Eq, Show)

newtype ThreadState = ThreadState (Map ThreadId (Set MessageId))
  deriving stock (Eq, Show)

newtype ContactState = ContactState AddressBook
  deriving stock (Eq, Show)

data MailboxKind = Inbox | Sent | DraftsMailbox | Trash | ArchiveMailbox | CustomMailbox
  deriving stock (Eq, Show)

data MailboxMeta = MailboxMeta
  { mailboxName   :: !Text
  , mailboxKind   :: !MailboxKind
  , mailboxParent :: !(Maybe MailboxId)  -- hierarchy (§11's own comment)
  }
  deriving stock (Eq, Show)

-- | The canonical mailbox-membership relation (§11). Multi-valued
-- deliberately: a message can be In("Inbox") and In("Work")
-- simultaneously.
data MailboxState = MailboxState
  { membership     :: !MailMembership
  , mailboxCatalog :: !(Map MailboxId MailboxMeta)
  }
  deriving stock (Eq, Show)

-- | Left minimal pending §21: Draft has no fields yet (deliberately
-- abstract, Owl.Domain.Opaque), so this can never hold anything real
-- until that phase gives Draft a concrete shape.
newtype DraftState = DraftState (Map MessageId Draft)
  deriving stock (Eq, Show)

data Application = Application
  { messages  :: !MessageState
  , threads   :: !ThreadState
  , contacts  :: !ContactState
  , mailboxes :: !MailboxState
  , drafts    :: !DraftState
  , sync      :: !(Map AccountId SyncState)
  }
  deriving stock (Eq, Show)

emptyApplication :: Application
emptyApplication = Application
  { messages  = MessageState Map.empty Set.empty Set.empty
  , threads   = ThreadState Map.empty
  , contacts  = ContactState (mkAddressBook [])
  , mailboxes = MailboxState (MailMembership Map.empty) Map.empty
  , drafts    = DraftState Map.empty
  , sync      = Map.empty
  }
