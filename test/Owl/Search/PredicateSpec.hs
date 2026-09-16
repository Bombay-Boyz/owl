module Owl.Search.PredicateSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (fromGregorian, secondsToDiffTime, UTCTime (..))
import qualified Data.UUID as UUID
import Test.Hspec

import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Attachment (Attachment (..))
import qualified Owl.Domain.Body as BodyT
import Owl.Domain.Flag (Flag (..))
import Owl.Domain.Id (AccountId (..), LocalId (..), MailboxId (..), MessageId (..), ThreadId (..))
import Owl.Domain.MailAddress (Address (..), addressEmail)
import Owl.Domain.Subject (Subject, mkSubject)
import Owl.Message.Identity (MessageIdentity (..))
import Owl.Message.Types (Message (..))
import Owl.Search.Predicate

mkAddr :: Text -> Address
mkAddr t = Address Nothing (either (error . show) id (mkEmailAddress t))

mkSub :: Text -> Subject
mkSub t = either (error . show) id (mkSubject t)

testAcct :: AccountId
testAcct = AccountId "acct"

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

msg1, msg2 :: Message
msg1 = Message
  { identity    = MessageIdentity { messageId = mkMid 1, rfcId = Nothing }
  , accountId   = testAcct
  , threadId    = ThreadId "thread-1"
  , sender      = mkAddr "alice@example.com"
  , recipients  = [mkAddr "bob@example.net"]
  , subject     = mkSub "Hello"
  , sentAt      = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "invoice attached") Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = []
  , replyTo    = []
  }
msg2 = Message
  { identity    = MessageIdentity { messageId = mkMid 2, rfcId = Nothing }
  , accountId   = testAcct
  , threadId    = ThreadId "thread-2"
  , sender      = mkAddr "carol@example.org"
  , recipients  = [mkAddr "alice@example.com"]
  , subject     = mkSub "Re: Hello"
  , sentAt      = UTCTime (fromGregorian 2026 1 5) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "annual report enclosed") Nothing
  , attachments = [Attachment Nothing "application/pdf" "PDFDATA"]
  , flags       = Set.singleton Seen
  , references  = []
  , replyTo    = []
  }

membership :: MailMembership
membership = MailMembership (Map.fromList
  [ (mkMid 1, Set.singleton (MailboxId "inbox"))
  , (mkMid 2, Set.fromList [MailboxId "inbox", MailboxId "work"])
  ])

spec :: Spec
spec = describe "matches (§15)" $ do
  it "From matches the exact sender" $
    matches membership msg1 (From (addressEmail (sender msg1))) `shouldBe` True
  it "From does not match a different sender" $
    matches membership msg2 (From (addressEmail (sender msg1))) `shouldBe` False
  it "To matches any recipient" $
    matches membership msg1 (To (addressEmail (mkAddr "bob@example.net"))) `shouldBe` True
  it "SubjectContains is a case-insensitive substring match" $
    matches membership msg1 (SubjectContains "hello") `shouldBe` True
  it "Body matches an exact phrase" $
    matches membership msg2 (Body (Phrase "annual report")) `shouldBe` True
  it "Body does not match an absent phrase" $
    matches membership msg1 (Body (Phrase "annual report")) `shouldBe` False
  it "HasAttachment is true only for messages carrying attachments" $ do
    matches membership msg1 HasAttachment `shouldBe` False
    matches membership msg2 HasAttachment `shouldBe` True
  it "IsUnread is true exactly when Seen is absent" $ do
    matches membership msg1 IsUnread `shouldBe` True
    matches membership msg2 IsUnread `shouldBe` False
  it "InMailbox consults MailMembership, not a Message field" $ do
    matches membership msg1 (InMailbox (MailboxId "inbox")) `shouldBe` True
    matches membership msg1 (InMailbox (MailboxId "work"))  `shouldBe` False
    matches membership msg2 (InMailbox (MailboxId "work"))  `shouldBe` True
  it "InThread matches the message's own threadId" $
    matches membership msg1 (InThread (ThreadId "thread-1")) `shouldBe` True
  it "After/Before bracket sentAt correctly" $ do
    matches membership msg1 (After (fromGregorian 2025 12 31))  `shouldBe` True
    matches membership msg1 (Before (fromGregorian 2025 12 31)) `shouldBe` False
  it "And requires every conjunct" $
    matches membership msg2 (And (HasAttachment :| [IsUnread])) `shouldBe` False
  it "Or requires at least one disjunct" $
    matches membership msg2 (Or (HasAttachment :| [IsUnread])) `shouldBe` True
  it "Not inverts" $
    matches membership msg1 (Not HasAttachment) `shouldBe` True
