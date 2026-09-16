-- | Reconciliation core (master spec §19) -- transcribed from the
-- master spec's own given code, not redesigned.
module Owl.Sync.Reconcile
  ( classify
  , reconcileOne
  , reconcile
  ) where

import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
import qualified Data.Map.Strict as Map

import Owl.Domain.Id (MessageId)
import Owl.Sync.Types

-- | Deliberately plain pattern matching, not a CRDT join-semilattice:
-- Owl has exactly one authority (the server) it is always eventually
-- reconciling against, so an explicit precedence rule is sufficient
-- and far cheaper than generic convergence machinery.
classify :: MessageId -> ReconciliationInput -> SyncDecision
classify mid input = case input of
  RemoteArrival cur                -> Pull (obsRef cur)
  LocalOnlyEdit _                  -> Push mid
  UnbaselinedConflict e cur        -> Conflict (mkConflict mid e (Just cur))
  RemoteDeleted _                  -> DeleteLocal mid
  Baseline lkr cur
    | lkr == cur                   -> NoChange
    | otherwise                    -> Pull (obsRef cur)
  EditUnderDeletion _ e            -> Conflict (mkConflict mid e Nothing)
  EditAgainstBaseline lkr cur e
    | lkr == cur                   -> Push mid
    | otherwise                    -> Conflict (mkConflict mid e (Just cur))

-- | Per-message resolution. Nothing only for the key combination
-- toReconciliationInput also returns Nothing for -- provably
-- unreachable given how reconcile builds its key set (below) -- so
-- reconcile treats it as the invariant violation it would actually be
-- if it ever fired, rather than silently dropping the key.
reconcileOne :: MessageId -> Maybe LocalRecord -> Maybe RemoteObservation -> Maybe SyncDecision
reconcileOne mid localRecord currentRemote =
  classify mid <$> toReconciliationInput localRecord currentRemote

reconcile :: LocalSnapshot -> RemoteSnapshot -> Either SyncError SyncPlan
reconcile local remote = do
  decisions <- traverse decide (toList (Map.keysSet local <> Map.keysSet remote))
  case nonEmpty decisions of
    Nothing -> pure (SyncPlan (NoChange :| []))  -- both snapshots empty: nothing to reconcile
    Just ds -> pure (SyncPlan ds)
  where
    decide mid = case reconcileOne mid (Map.lookup mid local) (Map.lookup mid remote) of
      Just d  -> Right d
      Nothing -> Left (ImpossibleReconciliationKey mid)
