-- | Reconciliation types (master spec §19). Most of this section's
-- types are given essentially verbatim in the master spec text;
-- transcribed carefully rather than redesigned. SyncState/SyncEvent/
-- SyncFailure live here (not in a separate state-machine module)
-- purely to avoid a circular import: SyncError's own
-- InvalidSyncTransition constructor needs SyncState/SyncEvent, and
-- Owl.Sync.State's transition needs SyncError -- co-locating the types
-- both sides need breaks the cycle.
module Owl.Sync.Types
  ( RemoteObservation (..)
  , LocalRecord (..)
  , ReconciliationInput (..)
  , toReconciliationInput
  , SyncConflict (..)
  , mkConflict
  , SyncFailure (..)
  , SyncState (..)
  , SyncEvent (..)
  , SyncError (..)
  , SyncDecision (..)
  , SyncPlan (..)
  , LocalSnapshot
  , RemoteSnapshot
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)

import Owl.Domain.Flag (Flag)
import Owl.Domain.Id (MailboxId, MessageId)
import Owl.Event (Event)
import Owl.Message.Identity (RemoteRef)

-- | "Relevant message state" (§19's own phrase) is the remote-reported
-- flag set -- the one piece of per-message remote state this phase has
-- a concrete need to compare. RemoteRef alone identifies WHICH
-- message/mailbox/epoch; obsFlags is what actually changes between
-- observations for Baseline's equality check to notice.
data RemoteObservation = RemoteObservation
  { obsRef   :: !RemoteRef
  , obsFlags :: !(Set Flag)
  }
  deriving stock (Eq, Show)

-- | The naive shape is a record of two Maybes, which makes a fifth,
-- meaningless state representable (§19's own reasoning, applying
-- §11's rule to the reconciler's own input) -- so this is a closed sum
-- over exactly the three states that mean something.
data LocalRecord
  = KnownRemote            !RemoteObservation
  | PendingEdit             !Event
  | KnownRemoteWithPending  !RemoteObservation !Event
  deriving stock (Eq, Show)

-- | Total: eight input combinations, seven of them meaningful. There
-- is deliberately no constructor for "no LocalRecord and no
-- RemoteObservation" -- reconcile only ever looks a key up here after
-- drawing it from the union of both snapshots' keys, so at least one
-- side is always present.
data ReconciliationInput
  = RemoteArrival          !RemoteObservation
  | LocalOnlyEdit           !Event
  | UnbaselinedConflict     !Event !RemoteObservation
  | RemoteDeleted           !RemoteObservation
  | Baseline                !RemoteObservation !RemoteObservation
  | EditUnderDeletion       !RemoteObservation !Event
  | EditAgainstBaseline     !RemoteObservation !RemoteObservation !Event
  deriving stock (Eq, Show)

-- | The eighth combination -- no LocalRecord, no RemoteObservation --
-- can't arise from reconcile's fold, so this returns Maybe rather than
-- smuggling a fake decision in for an input that should never reach
-- it.
toReconciliationInput :: Maybe LocalRecord -> Maybe RemoteObservation -> Maybe ReconciliationInput
toReconciliationInput Nothing                              Nothing    = Nothing
toReconciliationInput Nothing                              (Just cur) = Just (RemoteArrival cur)
toReconciliationInput (Just (PendingEdit e))                Nothing    = Just (LocalOnlyEdit e)
toReconciliationInput (Just (PendingEdit e))                (Just cur) = Just (UnbaselinedConflict e cur)
toReconciliationInput (Just (KnownRemote lkr))              Nothing    = Just (RemoteDeleted lkr)
toReconciliationInput (Just (KnownRemote lkr))              (Just cur) = Just (Baseline lkr cur)
toReconciliationInput (Just (KnownRemoteWithPending lkr e)) Nothing    = Just (EditUnderDeletion lkr e)
toReconciliationInput (Just (KnownRemoteWithPending lkr e)) (Just cur) = Just (EditAgainstBaseline lkr cur e)

data SyncConflict = SyncConflict
  { conflictMessageId         :: !MessageId
  , conflictLocalEdit         :: !Event
  , conflictRemoteObservation :: !(Maybe RemoteObservation)
  }
  deriving stock (Eq, Show)

-- | EditUnderDeletion is a genuine conflict (a local edit against a
-- message the server deleted) with no current remote state to attach
-- to it, so this must be constructible without one.
mkConflict :: MessageId -> Event -> Maybe RemoteObservation -> SyncConflict
mkConflict = SyncConflict

data SyncFailure
  = NetworkFailure Text
  | AuthenticationFailure Text
  | ProtocolFailure Text
  deriving stock (Eq, Show)

data SyncState = NotSynced | Syncing | Synchronized | NeedsRetry SyncFailure
  deriving stock (Eq, Show)

data SyncEvent
  = SyncStarted
  | RemoteChanged
  | LocalChanged
  | SyncCompleted
  | SyncFailed SyncFailure
  deriving stock (Eq, Show)

data SyncError
  = ImpossibleReconciliationKey MessageId
    -- ^ Provably dead given reconcile's own fold over the union of
    -- both snapshots' keys -- named per §28's rule against silently
    -- dropping a key instead.
  | InvalidSyncTransition SyncState SyncEvent
  deriving stock (Eq, Show)

-- | Keyed on the identity types already defined in §13, not a generic
-- LocalId/RemoteId pair -- a decision is always about a specific
-- message (MessageId) or a specific mailbox-level change.
data SyncDecision
  = Pull RemoteRef
  | Push MessageId
  | DeleteLocal MessageId
  | DeleteRemote RemoteRef
  | MoveMailbox MailboxId
  | NoChange
  | Conflict SyncConflict
  deriving stock (Eq, Show)

newtype SyncPlan = SyncPlan (NonEmpty SyncDecision)
  deriving newtype (Semigroup, Eq, Show)

type LocalSnapshot  = Map MessageId LocalRecord
type RemoteSnapshot = Map MessageId RemoteObservation
