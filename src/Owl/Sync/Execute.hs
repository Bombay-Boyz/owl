-- | Plan execution (master spec §19) -- separate from planning, and
-- where retries/idempotency live.
--
-- NOT YET IMPLEMENTED: executing a SyncPlan means performing the
-- actual IMAP/SMTP network calls and SQLite writes each SyncDecision
-- names -- real effects that belong to the provider adapter (§20),
-- not yet built. Honestly typed but incomplete, the same pattern as
-- Owl.Message.Boundary's decodeCharset/validateMessage before
-- purebred-email was chosen.
module Owl.Sync.Execute
  ( DecisionOutcome (..)
  , SyncOutcome (..)
  , execute
  ) where

import Owl.Sync.Types (SyncDecision, SyncFailure, SyncPlan)

data DecisionOutcome = DecisionSucceeded | DecisionFailed SyncFailure
  deriving stock (Eq, Show)

data SyncOutcome = SyncOutcome
  { outcomeSucceeded :: ![SyncDecision]
  , outcomeFailed    :: ![(SyncDecision, SyncFailure)]
  }
  deriving stock (Eq, Show)

execute :: SyncPlan -> IO SyncOutcome
execute = undefined
