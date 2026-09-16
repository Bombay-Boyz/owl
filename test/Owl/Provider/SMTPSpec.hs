-- | Tests the headers buildMail actually sets.
--
-- This is the only part of the SMTP path verifiable without a live
-- server, and it was silently wrong -- no Message-ID, no thread
-- headers -- while every other test passed. mime-mail's renderMail
-- adds neither of its own (confirmed from its source), so if buildMail
-- omits them, nothing downstream supplies them.
module Owl.Provider.SMTPSpec (spec) where

import Data.Text (Text)
import qualified Data.UUID as UUID
import qualified Network.Mail.Mime as Mime
import Test.Hspec

import Owl.Compose hiding (replyTo)
import qualified Owl.Compose as Compose
import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Body (Body (..))
import Owl.Domain.Id (AccountId (..), LocalId (..), MessageId (..), ThreadId (..))
import Owl.Domain.Identity (Identity (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (Subject, mkSubject)
import Owl.Message.Identity (MessageIdentity (..), parseRfcMessageId)
import Owl.Message.Types (Message (..))
import Owl.Provider.SMTP (buildMail)

import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)

testNow :: UTCTime
testNow = UTCTime (fromGregorian 2026 1 15) (secondsToDiffTime (14 * 3600 + 30 * 60 + 5))

mkAddr :: Text -> Address
mkAddr t = Address Nothing (either (error . show) id (mkEmailAddress t))

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

mkSub :: Text -> Subject
mkSub t = either (error . show) id (mkSubject t)

testIdentity :: Identity
testIdentity = Identity
  { identityAccountId    = AccountId "acct1"
  , identityEmailAddress = either (error . show) id (mkEmailAddress "alice@example.com")
  , identityDisplayName  = Just "Alice Smith"
  , identityIsDefault    = True
  }

originalMsg :: Message
originalMsg = Message
  { identity    = MessageIdentity
      { messageId = mkMid 1
      , rfcId     = Just (AccountId "acct1", maybe (error "bad fixture") id (parseRfcMessageId "<orig@example.com>"))
      }
  , accountId   = AccountId "acct1"
  , threadId    = ThreadId "t1"
  , sender      = mkAddr "bob@example.net"
  , recipients  = [mkAddr "alice@example.com"]
  , subject     = mkSub "Project update"
  , sentAt      = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
  , body        = Body (Just "line one") Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = []
  , replyTo     = []
  }

freshDraft :: Draft
freshDraft = (newDraft (mkMid 3) testIdentity (mkSub "Hi there"))
  { draftRecipients = [mkAddr "bob@example.net"]
  , draftBody       = Body (Just "hello") Nothing
  }

headersOf :: Draft -> Either String Mime.Headers
headersOf draft = case toEnvelope testNow draft of
  Left err  -> Left (show err)
  Right env -> Right (Mime.mailHeaders (buildMail env))

lookupHeader :: Text -> Mime.Headers -> Maybe Text
lookupHeader name hdrs =
  case [v | (k, v) <- hdrs, k == encodeName name] of
    (v : _) -> Just v
    []      -> Nothing
  where
    encodeName = \n -> case n of
      "Message-ID"  -> "Message-ID"
      "In-Reply-To" -> "In-Reply-To"
      "References"  -> "References"
      "Subject"     -> "Subject"
      "Date"        -> "Date"
      _             -> "unknown"

spec :: Spec
spec = describe "Owl.Provider.SMTP.buildMail -- transmitted headers" $ do
  it "sets a Message-ID on the transmitted copy" $
    case headersOf freshDraft of
      Left err   -> expectationFailure err
      Right hdrs -> lookupHeader "Message-ID" hdrs
        `shouldBe` Just "<00000003-0000-0000-0000-000000000000@example.com>"

  it "uses the SAME Message-ID as the stored copy -- they must not diverge" $
    case toEnvelope testNow freshDraft of
      Left err  -> expectationFailure (show err)
      Right env ->
        lookupHeader "Message-ID" (Mime.mailHeaders (buildMail env))
          `shouldBe` Just (envelopeMessageId env)

  it "does NOT clobber the Subject that simpleMail' already set" $
    case headersOf freshDraft of
      Left err   -> expectationFailure err
      Right hdrs -> lookupHeader "Subject" hdrs `shouldBe` Just "Hi there"

  it "sets In-Reply-To for a reply" $
    case Compose.replyTo (mkMid 4) ReplyToSender testIdentity originalMsg of
      Left err    -> expectationFailure (show err)
      Right draft -> case headersOf draft of
        Left err   -> expectationFailure err
        Right hdrs -> lookupHeader "In-Reply-To" hdrs `shouldBe` Just "<orig@example.com>"

  it "sets References for a reply" $
    case Compose.replyTo (mkMid 4) ReplyToSender testIdentity originalMsg of
      Left err    -> expectationFailure (show err)
      Right draft -> case headersOf draft of
        Left err   -> expectationFailure err
        Right hdrs -> lookupHeader "References" hdrs `shouldBe` Just "<orig@example.com>"

  it "sets a Date on the transmitted copy" $
    case headersOf freshDraft of
      Left err   -> expectationFailure err
      Right hdrs -> lookupHeader "Date" hdrs `shouldSatisfy` (/= Nothing)

  it "sets no In-Reply-To for a fresh compose" $
    case headersOf freshDraft of
      Left err   -> expectationFailure err
      Right hdrs -> lookupHeader "In-Reply-To" hdrs `shouldBe` Nothing
