module Owl.Provider.TypesSpec (spec) where

import qualified Data.Set as Set
import Data.Maybe (fromJust)
import Test.Hspec

import Owl.Domain.Flag (Flag (..))
import Owl.Domain.Id (MailboxId (..))
import Owl.Message.Identity (RemoteRef (..), UID, UIDValidity, mkUID, mkUIDValidity)
import Owl.Provider.Types
import Owl.Sync.Types (RemoteObservation (..))

mustUID :: Int -> UID
mustUID = fromJust . mkUID . fromIntegral

mustValidity :: Int -> UIDValidity
mustValidity = fromJust . mkUIDValidity . fromIntegral

freshCursor :: SyncCursor
freshCursor = SyncCursor
  { cursorMailboxId   = MailboxId "inbox"
  , cursorFolderName  = "INBOX"
  , cursorUidValidity = Nothing
  , cursorLastUid     = Nothing
  }

spec :: Spec
spec = describe "buildRemoteDelta (pure core, §20)" $ do
  it "on a first sync: every UID is new, no reset, cursor advances to the max UID" $ do
    let delta = buildRemoteDelta freshCursor (mustValidity 100)
          [mustUID 1, mustUID 2, mustUID 3]
          []
          [(mustUID 1, "one"), (mustUID 2, "two"), (mustUID 3, "three")]
    cursorUidValidity (deltaCursor delta) `shouldBe` Just (mustValidity 100)
    cursorLastUid (deltaCursor delta) `shouldBe` Just (mustUID 3)
    deltaUidValidityReset delta `shouldBe` False
    length (deltaNewMessages delta) `shouldBe` 3
    deltaUpdatedFlags delta `shouldBe` []

  it "on an empty mailbox's first sync: cursor's last UID stays Nothing" $ do
    let delta = buildRemoteDelta freshCursor (mustValidity 100) [] [] []
    cursorLastUid (deltaCursor delta) `shouldBe` Nothing
    deltaNewMessages delta `shouldBe` []

  it "on an incremental sync with the same UIDVALIDITY: only genuinely new UIDs are reported new" $ do
    let cursor = freshCursor { cursorUidValidity = Just (mustValidity 100), cursorLastUid = Just (mustUID 3) }
        delta  = buildRemoteDelta cursor (mustValidity 100)
          [mustUID 1, mustUID 2, mustUID 3, mustUID 4]
          [(mustUID 1, Set.singleton Seen), (mustUID 2, Set.empty), (mustUID 3, Set.singleton Flagged)]
          [(mustUID 4, "four")]
    deltaUidValidityReset delta `shouldBe` False
    cursorLastUid (deltaCursor delta) `shouldBe` Just (mustUID 4)
    map fst (deltaNewMessages delta) `shouldBe` [ImapRef (MailboxId "inbox") (mustValidity 100) (mustUID 4)]
    length (deltaUpdatedFlags delta) `shouldBe` 3
    RemoteObservation (ImapRef (MailboxId "inbox") (mustValidity 100) (mustUID 1)) (Set.singleton Seen)
      `shouldSatisfy` (`elem` deltaUpdatedFlags delta)

  it "reports a UIDVALIDITY change via deltaUidValidityReset" $ do
    let cursor = freshCursor { cursorUidValidity = Just (mustValidity 100), cursorLastUid = Just (mustUID 3) }
        delta  = buildRemoteDelta cursor (mustValidity 200) [mustUID 1] [] [(mustUID 1, "one")]
    deltaUidValidityReset delta `shouldBe` True
