-- | An in-memory StoreHandle IO (master spec §18's own gate: "storage
-- ... can be replaced by an in-memory test implementation"). Search is
-- a full scan over whatever is currently stored -- the same
-- simplification as Owl.Store.SQLite, and for the same reason (no
-- premature complexity until benchmarks justify it).
--
-- This implementation has no way to record mailbox membership at all
-- -- StoreHandle's own given interface (loadMessage/saveMessage/
-- searchMessages) has no membership-setting method, so InMailbox
-- predicates always evaluate empty here. An honest limitation of the
-- minimal given interface, not something this module silently hides.
module Owl.Store.Memory
  ( newMemoryStore
  ) where

import Data.IORef
import qualified Data.Map.Strict as Map

import Owl.Compose (Draft (draftId))
import Owl.Message.Identity (MessageIdentity (messageId))
import Owl.Message.Types (Message (identity))
import Owl.Search.Engine (buildSearchIndex, evaluate)
import Owl.Search.Predicate (MailMembership (..))
import Owl.Store.Types

newMemoryStore :: IO (StoreHandle IO)
newMemoryStore = do
  ref      <- newIORef Map.empty
  draftRef <- newIORef Map.empty
  pure StoreHandle
    { loadMessage = \mid -> do
        store <- readIORef ref
        pure (maybe (Left (MessageNotFound mid)) Right (Map.lookup mid store))
    , saveMessage = \msg -> do
        atomicModifyIORef' ref (\store -> (Map.insert (messageId (identity msg)) msg store, ()))
        pure (Right ())
    , searchMessages = \q -> do
        store <- readIORef ref
        let idx = buildSearchIndex (MailMembership Map.empty) (Map.elems store)
        pure (Right (evaluate idx q))
    , loadDraft = \mid -> do
        drafts <- readIORef draftRef
        pure (maybe (Left (DraftNotFound mid)) Right (Map.lookup mid drafts))
    , saveDraft = \draft -> do
        atomicModifyIORef' draftRef (\m -> (Map.insert (draftId draft) draft m, ()))
        pure (Right ())
    , deleteDraft = \mid -> do
        atomicModifyIORef' draftRef (\m -> (Map.delete mid m, ()))
        pure (Right ())
    , listDrafts = do
        drafts <- readIORef draftRef
        pure (Right (Map.keys drafts))
    }
