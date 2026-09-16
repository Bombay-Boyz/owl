-- | Sync lifecycle state machine and retry policy (master spec §19).
module Owl.Sync.State
  ( Attempt (..)
  , Duration
  , RetryPolicy (..)
  , nextAttempt
  , exponentialBackoff
  , transition
  ) where

import Data.Time (NominalDiffTime)

import Owl.Domain.Numeric (PositiveInt, unPositiveInt)
import Owl.Sync.Types (SyncError (..), SyncEvent (..), SyncState (..))

newtype Attempt = Attempt Int
  deriving stock (Show)
  deriving newtype (Eq, Ord)

type Duration = NominalDiffTime

data RetryPolicy = RetryPolicy
  { maxAttempts :: !PositiveInt
  , backoff     :: !(Attempt -> Duration)
  }

-- | Bounded exponential backoff, never unbounded recursion (§19):
-- maxAttempts is what bounds the retry count; backoff only shapes the
-- per-attempt delay.
nextAttempt :: RetryPolicy -> Attempt -> Maybe Duration
nextAttempt policy attempt@(Attempt n)
  | n >= unPositiveInt (maxAttempts policy) = Nothing
  | otherwise                                = Just (backoff policy attempt)

-- | Doubling from a base duration -- standard exponential backoff, not
-- invented for Owl.
exponentialBackoff :: NominalDiffTime -> Attempt -> Duration
exponentialBackoff base (Attempt n) = base * (2 ^ max 0 (n - 1))

-- | A plain one-account state machine (§19's own note: "not a map" --
-- the caller applies the result at that account's key in
-- Application.sync, §11/§27). Any (state, event) pair not covered by
-- the named transitions below is a genuine invariant violation, named
-- via InvalidSyncTransition rather than silently accepted.
transition :: SyncState -> SyncEvent -> Either SyncError SyncState
transition state event = case (state, event) of
  (NotSynced, SyncStarted)      -> Right Syncing
  (Syncing, SyncCompleted)      -> Right Synchronized
  (Syncing, SyncFailed failure) -> Right (NeedsRetry failure)
  (Syncing, RemoteChanged)      -> Right Syncing
  (Syncing, LocalChanged)       -> Right Syncing
  (Synchronized, RemoteChanged) -> Right Syncing
  (Synchronized, LocalChanged)  -> Right Syncing
  (Synchronized, SyncStarted)   -> Right Syncing
  (NeedsRetry _, SyncStarted)   -> Right Syncing
  (NeedsRetry f, RemoteChanged) -> Right (NeedsRetry f)
  (NeedsRetry f, LocalChanged)  -> Right (NeedsRetry f)
  (s, e)                        -> Left (InvalidSyncTransition s e)
