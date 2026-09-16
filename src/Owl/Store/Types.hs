-- | Local persistence, the narrow handle (master spec §18): the domain
-- never imports a concrete database implementation, and an in-memory
-- implementation can stand in for tests -- see Owl.Store.Memory and
-- Owl.Store.SQLite, both of which satisfy this same StoreHandle.
--
-- loadDraft/saveDraft/deleteDraft/listDrafts are additions beyond
-- §18's given three methods -- justified the same way every other
-- addition in this codebase has been: an already-shipped feature (§21
-- compose/reply/send, and Owl.Application.DraftState) requires it.
-- Without these, a Draft only ever lived in memory and was lost on
-- restart -- a real functional hole, not an optimization to defer.
module Owl.Store.Types
  ( StoreQuery (..)
  , StorePlan (..)
  , StoreQueryError
  , planQuery
  , StoreError (..)
  , StoreHandle (..)
  ) where

import Data.Set (Set)
import Data.Text (Text)

import Owl.Compose (Draft)
import Owl.Domain.Id (MailboxId, MessageId)
import Owl.Message.Types (Message)
import Owl.Search.Predicate (Query)

data StoreQuery = GetMessage MessageId | Search Query | ListMailbox MailboxId

data StorePlan
  = PlanGetMessage MessageId
  | PlanSearch Query
  | PlanListMailbox MailboxId
  deriving stock (Eq, Show)

data StoreQueryError
  deriving stock (Eq, Show)

planQuery :: StoreQuery -> Either StoreQueryError StorePlan
planQuery (GetMessage mid)   = Right (PlanGetMessage mid)
planQuery (Search q)         = Right (PlanSearch q)
planQuery (ListMailbox mbid) = Right (PlanListMailbox mbid)

data StoreError
  = MessageNotFound MessageId
  | DraftNotFound MessageId
  | MailboxNotFound MailboxId
  | ConnectionError Text
  | SchemaVersionMismatch Int (Maybe Int)  -- (expected, found)
  | ConstraintViolation Text
  deriving stock (Eq, Show)

data StoreHandle m = StoreHandle
  { loadMessage    :: MessageId -> m (Either StoreError Message)
  , saveMessage    :: Message   -> m (Either StoreError ())
  , searchMessages :: Query     -> m (Either StoreError (Set MessageId))
  , loadDraft      :: MessageId -> m (Either StoreError Draft)
  , saveDraft      :: Draft     -> m (Either StoreError ())
  , deleteDraft    :: MessageId -> m (Either StoreError ())
  , listDrafts     :: m (Either StoreError [MessageId])
  }
