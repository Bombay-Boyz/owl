module Owl.Search.EngineSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (fromGregorian, secondsToDiffTime, UTCTime (..))
import qualified Data.UUID as UUID
import Hedgehog (Gen, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Attachment (Attachment (..))
import qualified Owl.Domain.Body as BodyT
import Owl.Domain.Flag (Flag (..))
import Owl.Domain.Id (AccountId (..), LocalId (..), MailboxId (..), MessageId (..), ThreadId (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (Subject, mkSubject)
import Owl.Message.Identity (MessageIdentity (..))
import Owl.Message.Types (Message (..))
import Owl.Search.Engine
import Owl.Search.Predicate
import Owl.Search.Rank (defaultBM25Parameters)

mkAddr :: Text -> Address
mkAddr t = Address Nothing (either (error . show) id (mkEmailAddress t))

mkSub :: Text -> Subject
mkSub t = either (error . show) id (mkSubject t)

testAcct :: AccountId
testAcct = AccountId "acct"

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

corpus :: [Message]
corpus = [msgA, msgB, msgC, msgD]

msgA, msgB, msgC, msgD :: Message
msgA = Message
  { identity    = MessageIdentity { messageId = mkMid 1, rfcId = Nothing }
  , accountId   = testAcct
  , threadId    = ThreadId "t1"
  , sender      = mkAddr "alice@example.com"
  , recipients  = [mkAddr "bob@example.net"]
  , subject     = mkSub "Invoice for March"
  , sentAt      = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "please find the invoice attached") Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = []
  , replyTo    = []
  }
msgB = Message
  { identity    = MessageIdentity { messageId = mkMid 2, rfcId = Nothing }
  , accountId   = testAcct
  , threadId    = ThreadId "t2"
  , sender      = mkAddr "carol@example.org"
  , recipients  = [mkAddr "alice@example.com"]
  , subject     = mkSub "Annual report"
  , sentAt      = UTCTime (fromGregorian 2026 1 5) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "the annual report is enclosed") Nothing
  , attachments = [Attachment Nothing "application/pdf" "PDFDATA"]
  , flags       = Set.singleton Seen
  , references  = []
  , replyTo    = []
  }
msgC = Message
  { identity    = MessageIdentity { messageId = mkMid 3, rfcId = Nothing }
  , accountId   = testAcct
  , threadId    = ThreadId "t1"
  , sender      = mkAddr "bob@example.net"
  , recipients  = [mkAddr "alice@example.com"]
  , subject     = mkSub "Re: Invoice for March"
  , sentAt      = UTCTime (fromGregorian 2026 1 2) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "thanks, paid") Nothing
  , attachments = []
  , flags       = Set.singleton Seen
  , references  = []
  , replyTo    = []
  }
msgD = Message
  { identity    = MessageIdentity { messageId = mkMid 4, rfcId = Nothing }
  , accountId   = testAcct
  , threadId    = ThreadId "t3"
  , sender      = mkAddr "dave@example.com"
  , recipients  = [mkAddr "alice@example.com", mkAddr "bob@example.net"]
  , subject     = mkSub "Lunch?"
  , sentAt      = UTCTime (fromGregorian 2026 2 10) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "want to get lunch") Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = []
  , replyTo    = []
  }

membership :: MailMembership
membership = MailMembership (Map.fromList
  [ (mkMid 1, Set.singleton (MailboxId "inbox"))
  , (mkMid 2, Set.fromList [MailboxId "inbox", MailboxId "work"])
  , (mkMid 3, Set.singleton (MailboxId "inbox"))
  , (mkMid 4, Set.singleton (MailboxId "personal"))
  ])

idx :: SearchIndex
idx = buildSearchIndex membership corpus

genLeafPredicate :: Gen Predicate
genLeafPredicate = Gen.choice
  [ From <$> Gen.element (map mustAddr addrs)
  , To   <$> Gen.element (map mustAddr addrs)
  , SubjectContains <$> Gen.element ["invoice", "report", "lunch", "nonexistentword"]
  , (Body . Phrase) <$> Gen.element ["invoice attached", "annual report", "paid", "xyz"]
  , pure HasAttachment
  , pure IsUnread
  , InMailbox <$> Gen.element (map MailboxId ["inbox", "work", "personal"])
  , InThread <$> Gen.element (map ThreadId ["t1", "t2", "t3"])
  , After <$> Gen.element [fromGregorian 2025 12 31, fromGregorian 2026 1 3]
  , Before <$> Gen.element [fromGregorian 2025 12 31, fromGregorian 2026 1 3]
  ]
  where
    addrs = ["alice@example.com", "bob@example.net", "carol@example.org", "dave@example.com"]
    mustAddr t = either (error . show) id (mkEmailAddress t)

genPredicate :: Int -> Gen Predicate
genPredicate n
  | n <= 0    = genLeafPredicate
  | otherwise = Gen.choice
      [ genLeafPredicate
      , And <$> genNonEmpty (genPredicate (n - 1))
      , Or  <$> genNonEmpty (genPredicate (n - 1))
      , Not <$> genPredicate (n - 1)
      ]

genNonEmpty :: Gen a -> Gen (NonEmpty a)
genNonEmpty g = (:|) <$> g <*> Gen.list (Range.linear 0 2) g

spec :: Spec
spec = do
  describe "evaluate agrees with matches (the §32-required property)" $
    it "produces the same result set as a direct scan for any generated predicate" $ hedgehog $ do
      predicate <- forAll (genPredicate 3)
      let expected = Set.fromList [ messageId (identity m) | m <- corpus, matches membership m predicate ]
      evaluate idx predicate === expected

  describe "search" $
    it "returns exactly the messages evaluate identifies as candidates" $ do
      let q = Or (SubjectContains "invoice" :| [Body (Phrase "invoice")])
      Set.fromList (search defaultMaxCandidates defaultBM25Parameters idx q) `shouldBe` evaluate idx q
