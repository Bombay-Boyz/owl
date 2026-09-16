module Owl.RulesSpec (spec) where

import qualified Data.Set as Set
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Hedgehog (forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Owl.Domain.Address (mkEmailAddress)
import qualified Owl.Domain.Body as BodyT
import Owl.Domain.Id (AccountId (..), LabelId (..), LocalId (..), MailboxId (..), MessageId (..), ThreadId (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (mkSubject)
import Owl.Message.Identity (MessageIdentity (..))
import Owl.Message.Types (Message (..))
import Owl.Rules
import Owl.Search.Predicate (Predicate (..))

mkAddr :: Text -> Address
mkAddr t = Address Nothing (either (error . show) id (mkEmailAddress t))

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

testMsg :: Message
testMsg = Message
  { identity    = MessageIdentity { messageId = mkMid 1, rfcId = Nothing }
  , accountId   = AccountId "acct"
  , threadId    = ThreadId "t1"
  , sender      = mkAddr "alice@example.com"
  , recipients  = [mkAddr "bob@example.net"]
  , subject     = either (error . show) id (mkSubject "Invoice for March")
  , sentAt      = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "please find the invoice attached") Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = []
  , replyTo     = []
  }

alwaysMatches :: Predicate
alwaysMatches = SubjectContains ""

neverMatches :: Predicate
neverMatches = SubjectContains "this text will never appear anywhere"

mkRule :: Predicate -> NonEmpty Action -> Rule
mkRule = Rule

spec :: Spec
spec = do
  describe "evaluateRules -- basic matching" $ do
    it "fires a matching rule's actions" $
      evaluateRules [mkRule alwaysMatches (MarkRead :| [])] testMsg `shouldBe` [MarkRead]

    it "does not fire a non-matching rule's actions" $
      evaluateRules [mkRule neverMatches (MarkRead :| [])] testMsg `shouldBe` []

    it "returns [] when no rules are given" $
      evaluateRules [] testMsg `shouldBe` []

  describe "evaluateRules -- read-state conflict (last matching rule wins)" $ do
    it "MarkUnread overrides an earlier MarkRead" $
      evaluateRules
        [ mkRule alwaysMatches (MarkRead :| [])
        , mkRule alwaysMatches (MarkUnread :| [])
        ]
        testMsg
        `shouldBe` [MarkUnread]

    it "MarkRead overrides an earlier MarkUnread (order matters, not the specific action)" $
      evaluateRules
        [ mkRule alwaysMatches (MarkUnread :| [])
        , mkRule alwaysMatches (MarkRead :| [])
        ]
        testMsg
        `shouldBe` [MarkRead]

  describe "evaluateRules -- destination conflict" $ do
    it "a later Move overrides an earlier Archive" $
      evaluateRules
        [ mkRule alwaysMatches (Archive :| [])
        , mkRule alwaysMatches (Move (MailboxId "projects") :| [])
        ]
        testMsg
        `shouldBe` [Move (MailboxId "projects")]

    it "Delete wins over a LATER Move, even though Delete is not last (absolute precedence)" $
      evaluateRules
        [ mkRule alwaysMatches (Delete :| [])
        , mkRule alwaysMatches (Move (MailboxId "projects") :| [])
        ]
        testMsg
        `shouldBe` [Delete]

    it "Delete wins over an EARLIER Move (absolute precedence, not just last-wins)" $
      evaluateRules
        [ mkRule alwaysMatches (Move (MailboxId "projects") :| [])
        , mkRule alwaysMatches (Delete :| [])
        ]
        testMsg
        `shouldBe` [Delete]

  describe "evaluateRules -- labels are additive" $ do
    it "includes labels from multiple different matching rules" $
      evaluateRules
        [ mkRule alwaysMatches (Label (LabelId "work") :| [])
        , mkRule alwaysMatches (Label (LabelId "urgent") :| [])
        ]
        testMsg
        `shouldBe` [Label (LabelId "work"), Label (LabelId "urgent")]

    it "deduplicates the same label fired by more than one rule" $
      evaluateRules
        [ mkRule alwaysMatches (Label (LabelId "work") :| [])
        , mkRule alwaysMatches (Label (LabelId "work") :| [])
        ]
        testMsg
        `shouldBe` [Label (LabelId "work")]

  describe "evaluateRules -- combined categories coexist" $
    it "a label, a read-state action, and a destination action all appear together" $
      evaluateRules [mkRule alwaysMatches (Label (LabelId "work") :| [MarkRead, Archive])] testMsg
        `shouldBe` [Label (LabelId "work"), MarkRead, Archive]

  describe "evaluateRules -- property: at most one read-state and one destination action" $
    it "never returns more than one read-state action or more than one destination action, for any rule list where every rule always matches" $ hedgehog $ do
      n <- forAll (Gen.int (Range.linear 1 10))
      let rules = [ mkRule alwaysMatches (MarkRead :| [Archive]) | _ <- [1 .. n] ]
          result = evaluateRules rules testMsg
          readStateCount   = length (filter (`elem` [MarkRead, MarkUnread]) result)
          destinationCount = length (filter isDestination result)
          isDestination Archive  = True
          isDestination (Move _) = True
          isDestination Delete   = True
          isDestination _        = False
      readStateCount === 1
      destinationCount === 1
