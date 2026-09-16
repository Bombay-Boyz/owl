-- | Thread reconstruction (master spec §14). Uses the JWZ threading
-- algorithm, per §14's explicit instruction not to invent a heuristic.
--
-- See ContainerKey's own Haddock for the one real design decision this
-- module makes beyond what the spec pins down: a "known but absent"
-- referenced message doesn't have an Owl MessageId (it was never
-- ingested), so the build-time container graph is keyed by either a
-- real MessageId or an as-yet-unresolved (AccountId, ValidatedRfcId)
-- pair, converging to the given MessageNode/ThreadForest shape only at
-- the very end.
module Owl.Thread
  ( MessageNode (..)
  , ThreadForest (..)
  , ThreadBuildState
  , ThreadError (..)
  , messageReferences
  , resolveReference
  , wouldCreateCycle
  , threadMessages
  ) where

import Control.Monad (foldM)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Time (UTCTime)

import Owl.Domain.Id (AccountId, MessageId)
import Owl.Message.Identity (MessageIdentity (..), ValidatedRfcId)
import Owl.Message.Types (Message (..))

data MessageNode = MessageNode
  { nodeMessage  :: Maybe Message
  , nodeChildren :: [MessageNode]
  }
  deriving stock (Eq, Show)

newtype ThreadForest = ThreadForest (NonEmpty MessageNode)
  deriving stock (Eq, Show)

-- | Raw referenced ids as parsed straight from Message-ID/In-Reply-To/
-- References headers, populated onto Message.references at the
-- message boundary (§12). Kept as a distinct name at call sites, per
-- the master spec's own convention (matches Query/Predicate in §15),
-- even though it is currently a direct field read.
messageReferences :: Message -> [ValidatedRfcId]
messageReferences = references

-- | A container is keyed either by Owl's own MessageId (a message this
-- batch actually has) or by an as-yet-unresolved (AccountId,
-- ValidatedRfcId) pair (a message this batch only knows about via
-- someone else's reference to it) -- see this module's own Haddock.
-- Only KnownMessage containers can ever hold a real Message or take
-- part in a cycle check: §14's given wouldCreateCycle signature is
-- MessageId -> MessageId -> Bool, and a dummy container is freshly
-- created or reused within this same construction pass, so it can
-- never already be an ancestor of anything -- a cycle is structurally
-- impossible unless both endpoints are real messages.
data ContainerKey
  = KnownMessage !MessageId
  | UnresolvedReference !AccountId !ValidatedRfcId
  deriving stock (Eq, Ord, Show)

data Container = Container
  { containerMessage  :: !(Maybe Message)
  , containerParent   :: !(Maybe ContainerKey)
  , containerChildren :: ![ContainerKey]
  }

data ThreadBuildState = ThreadBuildState
  { tbsContainers :: !(Map ContainerKey Container)
  , tbsRfcIndex   :: !(Map (AccountId, ValidatedRfcId) MessageId)
  }

emptyState :: ThreadBuildState
emptyState = ThreadBuildState Map.empty Map.empty

resolveReference :: AccountId -> ValidatedRfcId -> ThreadBuildState -> Maybe MessageId
resolveReference acct rid state = Map.lookup (acct, rid) (tbsRfcIndex state)

-- | Before linking a container as a child of a candidate parent, walk
-- the parent's existing ancestor chain. True means linking would
-- create a cycle.
wouldCreateCycle :: ThreadBuildState -> MessageId -> MessageId -> Bool
wouldCreateCycle state childId candidateParentId = walk (Just (KnownMessage candidateParentId))
  where
    walk Nothing = False
    walk (Just key) = case key of
      KnownMessage currentId
        | currentId == childId -> True
      _ -> walk (containerParent =<< Map.lookup key (tbsContainers state))

data ThreadError
  = DuplicateMessageIdentity MessageId
  | EmptyThreadForestProduced
    -- ^ Provably unreachable given a NonEmpty input -- pruneTree never
    -- drops a container holding a real message, so the root set always
    -- yields at least one surviving node. Named rather than silently
    -- assumed, per §28's rule against escape-hatch errors.
  deriving stock (Eq, Show)

threadMessages :: AccountId -> NonEmpty Message -> Either ThreadError ThreadForest
threadMessages acct msgs = do
  registered <- foldM registerMessage emptyState msgs
  let linked = foldl' (linkMessage acct) registered msgs
      roots  = [ k | (k, c) <- Map.toList (tbsContainers linked), not (isJust (containerParent c)) ]
      pruned = concatMap (pruneTree . toMessageNode linked) roots
  case NE.nonEmpty (sortOn nodeSortKey pruned) of
    Nothing -> Left EmptyThreadForestProduced
    Just ne -> Right (ThreadForest ne)

registerMessage :: ThreadBuildState -> Message -> Either ThreadError ThreadBuildState
registerMessage state msg
  | Map.member key (tbsContainers state) = Left (DuplicateMessageIdentity mid)
  | otherwise = Right state
      { tbsContainers = Map.insert key (Container (Just msg) Nothing []) (tbsContainers state)
      , tbsRfcIndex   = maybe (tbsRfcIndex state) insertRfc (rfcId (identity msg))
      }
  where
    mid = messageId (identity msg)
    key = KnownMessage mid
    insertRfc (owningAcct, rid) = Map.insert (owningAcct, rid) mid (tbsRfcIndex state)

-- | Walks messageReferences left to right, linking each consecutive
-- pair as parent/child (JWZ's own chain-linking step), then links the
-- message's own container as the child of the last reference in the
-- chain.
linkMessage :: AccountId -> ThreadBuildState -> Message -> ThreadBuildState
linkMessage acct state msg = case foldl' step (state, Nothing) (messageReferences msg) of
  (finalState, lastKey) -> maybe finalState (linkParentChild finalState childKey) lastKey
  where
    childKey = KnownMessage (messageId (identity msg))

    step :: (ThreadBuildState, Maybe ContainerKey) -> ValidatedRfcId -> (ThreadBuildState, Maybe ContainerKey)
    step (st, mPrevKey) r =
      let (st', key) = resolveKey st r
          st''       = maybe st' (linkParentChild st' key) mPrevKey
      in (st'', Just key)

    resolveKey :: ThreadBuildState -> ValidatedRfcId -> (ThreadBuildState, ContainerKey)
    resolveKey st rid = case resolveReference acct rid st of
      Just knownId -> (st, KnownMessage knownId)
      Nothing ->
        let key = UnresolvedReference acct rid
        in if Map.member key (tbsContainers st)
             then (st, key)
             else (st { tbsContainers = Map.insert key (Container Nothing Nothing []) (tbsContainers st) }, key)

-- | Link childKey as a child of parentKey, unless childKey already has
-- a parent (never overwrite an existing link) or doing so would create
-- a cycle (checked only when both endpoints are real messages -- see
-- ContainerKey's own note on why a dummy container can never take part
-- in one).
linkParentChild :: ThreadBuildState -> ContainerKey -> ContainerKey -> ThreadBuildState
linkParentChild st childKey parentKey
  | childKey == parentKey = st
  | alreadyHasParent      = st
  | createsCycle          = st
  | otherwise             = st { tbsContainers = withNewParent (withNewChild (tbsContainers st)) }
  where
    alreadyHasParent = maybe False (isJust . containerParent) (Map.lookup childKey (tbsContainers st))
    createsCycle = case (childKey, parentKey) of
      (KnownMessage cid, KnownMessage pid) -> wouldCreateCycle st cid pid
      _                                    -> False
    withNewChild  = Map.adjust (\c -> c { containerChildren = childKey : containerChildren c }) parentKey
    withNewParent = Map.adjust (\c -> c { containerParent = Just parentKey }) childKey

toMessageNode :: ThreadBuildState -> ContainerKey -> MessageNode
toMessageNode st key = MessageNode
  { nodeMessage  = containerMessage container
  , nodeChildren = map (toMessageNode st) (containerChildren container)
  }
  where
    container = Map.findWithDefault (Container Nothing Nothing []) key (tbsContainers st)

-- | Empty, childless containers are dropped; empty containers with
-- exactly one child are spliced out (the child is promoted to the
-- empty container's position); empty containers with multiple children
-- are kept as a legitimate dummy grouping node -- the ordinary
-- "referenced but absent" MessageNode case. Applied uniformly whether
-- the container is at the root or nested, by having each container
-- return the zero-or-more nodes it becomes, concatenated by its
-- caller.
pruneTree :: MessageNode -> [MessageNode]
pruneTree node =
  let prunedChildren = concatMap pruneTree (nodeChildren node)
  in case (nodeMessage node, prunedChildren) of
       (Nothing, [])      -> []
       (Nothing, [only])  -> [only]
       (Nothing, several) -> [node { nodeChildren = several }]
       (Just _, children) -> [node { nodeChildren = children }]

-- | Sort key for deterministic sibling/root ordering, required for
-- §32's permutation-invariance property. A dummy node sorts by its
-- earliest real descendant. Returns Maybe rather than using a partial
-- minimum/head, per §30 -- Nothing is provably unreachable for any
-- node that survived pruneTree (an empty node with no descendants is
-- always dropped), but is represented honestly rather than assumed.
nodeSortKey :: MessageNode -> Maybe (UTCTime, MessageId)
nodeSortKey node = case nodeMessage node of
  Just msg -> Just (sentAt msg, messageId (identity msg))
  Nothing  -> case mapMaybe nodeSortKey (nodeChildren node) of
    []       -> Nothing
    subKeys  -> Just (minimum subKeys)
