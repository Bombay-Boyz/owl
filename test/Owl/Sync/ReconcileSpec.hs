module Owl.Sync.ReconcileSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.UUID as UUID
import Test.Hspec

import Owl.Domain.Flag (Flag (Seen))
import Owl.Domain.Id (LocalId (..), MailboxId (..), MessageId (..))
import Owl.Domain.Numeric (mkPositiveInt)
import Owl.Event (Event (..))
import Owl.Message.Identity (RemoteRef (..), UID, UIDValidity, mkUID, mkUIDValidity)
import Owl.Sync.Reconcile
import Owl.Sync.State
import Owl.Sync.Types

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

mustUID :: Int -> UID
mustUID n = maybe (error "bad fixture UID") id (mkUID (fromIntegral n))

mustUIDValidity :: Int -> UIDValidity
mustUIDValidity n = maybe (error "bad fixture UIDValidity") id (mkUIDValidity (fromIntegral n))

ref1, ref2 :: RemoteRef
ref1 = ImapRef (MailboxId "inbox") (mustUIDValidity 100) (mustUID 1)
ref2 = ImapRef (MailboxId "inbox") (mustUIDValidity 200) (mustUID 1)  -- same UID, new UIDVALIDITY epoch

obs1, obs2 :: RemoteObservation
obs1 = RemoteObservation ref1 (Set.singleton Seen)
obs2 = RemoteObservation ref2 (Set.singleton Seen)

spec :: Spec
spec = do
  describe "reconcile (§19 properties, each its own test, no network needed)" $ do
    it "is idempotent: yields only NoChange once remote reflects the last executed plan" $ do
      let mid    = mkMid 1
          local  = Map.singleton mid (KnownRemote obs1)
          remote = Map.singleton mid obs1
      reconcile local remote `shouldBe` Right (SyncPlan (NoChange :| []))

    it "treats a UIDVALIDITY change as Pull, never a spurious delete" $ do
      let mid    = mkMid 1
          local  = Map.singleton mid (KnownRemote obs1)
          remote = Map.singleton mid obs2
      reconcile local remote `shouldBe` Right (SyncPlan (Pull ref2 :| []))

    it "treats a brand new remote message as RemoteArrival -> Pull, never Conflict" $ do
      toReconciliationInput Nothing (Just obs1) `shouldBe` Just (RemoteArrival obs1)
      classify (mkMid 1) (RemoteArrival obs1) `shouldBe` Pull ref1

    it "detects remote deletion as DeleteLocal, never silently dropped" $ do
      toReconciliationInput (Just (KnownRemote obs1)) Nothing `shouldBe` Just (RemoteDeleted obs1)
      classify (mkMid 1) (RemoteDeleted obs1) `shouldBe` DeleteLocal (mkMid 1)

    it "surfaces edit-vs-deletion as Conflict, never DeleteLocal (the edit is never discarded)" $ do
      let event = MessageRead (mkMid 1)
      toReconciliationInput (Just (KnownRemoteWithPending obs1 event)) Nothing
        `shouldBe` Just (EditUnderDeletion obs1 event)
      classify (mkMid 1) (EditUnderDeletion obs1 event)
        `shouldBe` Conflict (mkConflict (mkMid 1) event Nothing)

    it "classify handles all seven ReconciliationInput constructors directly, not via a catch-all" $ do
      let event = MessageRead (mkMid 1)
      classify (mkMid 1) (RemoteArrival obs1)                     `shouldBe` Pull ref1
      classify (mkMid 1) (LocalOnlyEdit event)                    `shouldBe` Push (mkMid 1)
      classify (mkMid 1) (UnbaselinedConflict event obs1)         `shouldBe` Conflict (mkConflict (mkMid 1) event (Just obs1))
      classify (mkMid 1) (RemoteDeleted obs1)                     `shouldBe` DeleteLocal (mkMid 1)
      classify (mkMid 1) (Baseline obs1 obs1)                     `shouldBe` NoChange
      classify (mkMid 1) (Baseline obs1 obs2)                     `shouldBe` Pull ref2
      classify (mkMid 1) (EditUnderDeletion obs1 event)           `shouldBe` Conflict (mkConflict (mkMid 1) event Nothing)
      classify (mkMid 1) (EditAgainstBaseline obs1 obs1 event)    `shouldBe` Push (mkMid 1)
      classify (mkMid 1) (EditAgainstBaseline obs1 obs2 event)    `shouldBe` Conflict (mkConflict (mkMid 1) event (Just obs2))

    it "both snapshots empty yields a singleton NoChange plan" $
      reconcile Map.empty Map.empty `shouldBe` Right (SyncPlan (NoChange :| []))

  describe "transition (Owl.Sync.State)" $ do
    it "moves NotSynced -> Syncing on SyncStarted" $
      transition NotSynced SyncStarted `shouldBe` Right Syncing
    it "moves Syncing -> Synchronized on SyncCompleted" $
      transition Syncing SyncCompleted `shouldBe` Right Synchronized
    it "moves Syncing -> NeedsRetry on SyncFailed" $
      transition Syncing (SyncFailed (NetworkFailure "timeout"))
        `shouldBe` Right (NeedsRetry (NetworkFailure "timeout"))
    it "rejects an invalid transition rather than silently accepting it" $
      transition NotSynced SyncCompleted `shouldBe` Left (InvalidSyncTransition NotSynced SyncCompleted)

  describe "nextAttempt (bounded exponential backoff)" $ do
    it "returns Nothing once maxAttempts is reached" $ do
      let policy = RetryPolicy
            { maxAttempts = maybe (error "bad fixture") id (mkPositiveInt 3)
            , backoff     = exponentialBackoff 1
            }
      nextAttempt policy (Attempt 3) `shouldBe` Nothing
    it "doubles the duration on each attempt under maxAttempts" $ do
      let policy = RetryPolicy
            { maxAttempts = maybe (error "bad fixture") id (mkPositiveInt 5)
            , backoff     = exponentialBackoff 1
            }
      nextAttempt policy (Attempt 1) `shouldBe` Just 1
      nextAttempt policy (Attempt 2) `shouldBe` Just 2
      nextAttempt policy (Attempt 3) `shouldBe` Just 4
