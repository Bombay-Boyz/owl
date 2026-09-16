module Owl.Index.DeltaSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Hedgehog (forAll, (===))
import qualified Hedgehog.Gen as Gen
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import qualified Owl.Domain.Body as BodyT
import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Id (AccountId (..), LocalId (..), MailboxId (..), MessageId (..), ThreadId (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (Subject, mkSubject)
import Owl.Event
import Owl.Index.Delta
import Owl.Message.Identity (MessageIdentity (..))
import Owl.Message.Types (Message (..))
import Owl.Search.Engine (buildSearchIndex)
import Owl.Search.Predicate (MailMembership (..))

mkAddr :: Text -> Address
mkAddr t = Address Nothing (either (error . show) id (mkEmailAddress t))

mkSub :: Text -> Subject
mkSub t = either (error . show) id (mkSubject t)

testAcct :: AccountId
testAcct = AccountId "acct"

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

mkMsg :: Int -> Text -> [MailboxId] -> Message
mkMsg n subjectText _ = Message
  { identity    = MessageIdentity { messageId = mkMid n, rfcId = Nothing }
  , accountId   = testAcct
  , threadId    = ThreadId ("t" <> pack (show n))
  , sender      = mkAddr "alice@example.com"
  , recipients  = [mkAddr "bob@example.net"]
  , subject     = mkSub subjectText
  , sentAt      = UTCTime (fromGregorian 2026 1 n) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "hello world") Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = []
  , replyTo    = []
  }
  where
    pack = Text.pack

mid1, mid2 :: MailboxId
mid1 = MailboxId "inbox"
mid2 = MailboxId "work"

msgA, msgB :: Message
msgA = mkMsg 1 "Hello" []
msgB = mkMsg 2 "World" []

spec :: Spec
spec = do
  describe "deltaFor (structural derivation from Event's constructor, section 17)" $ do
    it "MessageReceived touches both search and thread indexes" $ do
      let d = deltaFor (MessageReceived msgA)
      searchDelta d `shouldSatisfy` isJust
      threadDelta d `shouldSatisfy` isJust

    it "MessageRead touches neither index" $
      deltaFor (MessageRead (mkMid 1)) `shouldBe` IndexDelta Nothing Nothing

    it "MessageUnread touches neither index" $
      deltaFor (MessageUnread (mkMid 1)) `shouldBe` IndexDelta Nothing Nothing

    it "MessageArchived touches neither index" $
      deltaFor (MessageArchived (mkMid 1)) `shouldBe` IndexDelta Nothing Nothing

    it "MessageMoved touches only the search index (membership change)" $ do
      let d = deltaFor (MessageMoved (mkMid 1) mid1 mid2)
      searchDelta d `shouldBe` Just (IndexMembershipChange (mkMid 1) (Set.singleton mid2) (Set.singleton mid1))
      threadDelta d `shouldBe` Nothing

    it "MessageLabeled adds exactly one mailbox, removes none" $
      deltaFor (MessageLabeled (mkMid 1) mid1)
        `shouldBe` IndexDelta (Just (IndexMembershipChange (mkMid 1) (Set.singleton mid1) Set.empty)) Nothing

    it "MessageUnlabeled removes exactly one mailbox, adds none" $
      deltaFor (MessageUnlabeled (mkMid 1) mid1)
        `shouldBe` IndexDelta (Just (IndexMembershipChange (mkMid 1) Set.empty (Set.singleton mid1))) Nothing

    it "MessageSent touches neither index (no Message content in its payload)" $
      deltaFor (MessageSent (mkMid 1)) `shouldBe` IndexDelta Nothing Nothing

  describe "applySearchIndexDelta / rebuild-equals-incremental (section 17, tested not assumed)" $ do
    it "incrementally building equals batch-building the same messages and membership" $ do
      let membership = MailMembership (Map.fromList [(mkMid 1, Set.singleton mid1), (mkMid 2, Set.fromList [mid1, mid2])])
          batch = buildSearchIndex membership [msgA, msgB]

          empty0 = buildSearchIndex (MailMembership Map.empty) []
          afterMsgs = foldl (flip applySearchIndexDelta) empty0
            [IndexNewMessage msgA, IndexNewMessage msgB]
          incremental = foldl (flip applySearchIndexDelta) afterMsgs
            [ IndexMembershipChange (mkMid 1) (Set.singleton mid1) Set.empty
            , IndexMembershipChange (mkMid 2) (Set.fromList [mid1, mid2]) Set.empty
            ]

      incremental `shouldBe` batch

    it "is invariant under the order messages are incrementally inserted" $ hedgehog $ do
      order <- forAll (Gen.shuffle [IndexNewMessage msgA, IndexNewMessage msgB])
      let empty0 = buildSearchIndex (MailMembership Map.empty) []
          resultInOrder = foldl (flip applySearchIndexDelta) empty0 [IndexNewMessage msgA, IndexNewMessage msgB]
          resultShuffled = foldl (flip applySearchIndexDelta) empty0 order
      resultShuffled === resultInOrder

  describe "applyThreadIndexDelta" $
    it "records the message under its own threadId" $ do
      let delta = ThreadIndexDelta (threadId msgA) msgA
          idx   = applyThreadIndexDelta delta emptyThreadIndex
      idx `shouldBe` ThreadIndex (Map.singleton (threadId msgA) (Map.singleton (mkMid 1) msgA))

isJust :: Maybe a -> Bool
isJust = maybe False (const True)
