module Owl.ThreadSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Hedgehog (forAll, (===))
import qualified Hedgehog.Gen as Gen
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import qualified Data.Text as Text

import Owl.Domain.Body (Body (..))
import Owl.Domain.Id (AccountId (..), LocalId (..), MessageId (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Subject (Subject, mkSubject)
import Owl.Message.Identity (MessageIdentity (..), parseRfcMessageId, singletonThreadId)
import Owl.Message.Types (Message (..))
import Owl.Thread

testAccount :: AccountId
testAccount = AccountId "acct"

testMessageId :: Int -> MessageId
testMessageId n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

testTime :: Int -> UTCTime
testTime n = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime (fromIntegral n))

testAddress :: Address
testAddress = case mkEmailAddress "alice@example.com" of
  Right addr -> Address Nothing addr
  Left err   -> error ("bad test fixture: " <> show err)

testSubject :: Subject
testSubject = case mkSubject "test" of
  Right s  -> s
  Left err -> error ("bad test fixture: " <> show err)

mkTestMessage :: Int -> [String] -> Maybe String -> Message
mkTestMessage n refs ownRfc = Message
  { identity    = MessageIdentity
      { messageId = testMessageId n
      , rfcId     = (\r -> (testAccount, mustRfcId r)) <$> ownRfc
      }
  , accountId   = testAccount
  , threadId    = singletonThreadId (testMessageId n)
  , sender      = testAddress
  , recipients  = [testAddress]
  , subject     = testSubject
  , sentAt      = testTime n
  , body        = Body Nothing Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = map mustRfcId refs
  , replyTo    = []
  }
  where
    mustRfcId r = case parseRfcMessageId ("<" <> pack r <> "@example.com>") of
      Just rid -> rid
      Nothing  -> error ("bad test fixture rfc id: " <> r)
    pack = Text.pack

spec :: Spec
spec = describe "threadMessages (JWZ, §14)" $ do
  it "threads a simple reply chain A <- B <- C" $ do
    let a = mkTestMessage 1 [] (Just "a")
        b = mkTestMessage 2 ["a"] (Just "b")
        c = mkTestMessage 3 ["a", "b"] (Just "c")
    case threadMessages testAccount (a :| [b, c]) of
      Left err -> expectationFailure (show err)
      Right (ThreadForest (root :| [])) -> do
        nodeMessage root `shouldBe` Just a
        case nodeChildren root of
          [child] -> do
            nodeMessage child `shouldBe` Just b
            map nodeMessage (nodeChildren child) `shouldBe` [Just c]
          other -> expectationFailure ("expected one child, got " <> show (length other))
      Right (ThreadForest roots) -> expectationFailure ("expected one root, got " <> show (NE.length roots))

  it "groups two replies to an unreceived ancestor under one dummy root" $ do
    let b = mkTestMessage 1 ["missing"] (Just "b")
        c = mkTestMessage 2 ["missing"] (Just "c")
    case threadMessages testAccount (b :| [c]) of
      Left err -> expectationFailure (show err)
      Right (ThreadForest (root :| [])) -> do
        nodeMessage root `shouldBe` Nothing
        map nodeMessage (nodeChildren root) `shouldMatchList` [Just b, Just c]
      Right (ThreadForest roots) -> expectationFailure ("expected one dummy root, got " <> show (NE.length roots))

  it "rejects a duplicate message identity" $ do
    let a1 = mkTestMessage 1 [] Nothing
        a2 = mkTestMessage 1 [] Nothing
    threadMessages testAccount (a1 :| [a2]) `shouldBe` Left (DuplicateMessageIdentity (testMessageId 1))

  it "terminates and links safely on a cyclic reference (A references B, B references A)" $ do
    let a = mkTestMessage 1 ["b"] (Just "a")
        b = mkTestMessage 2 ["a"] (Just "b")
    case threadMessages testAccount (a :| [b]) of
      Left err -> expectationFailure (show err)
      Right (ThreadForest roots) ->
        length (NE.toList roots) `shouldSatisfy` (> 0)

  it "is invariant under permutation of the input order" $ hedgehog $ do
    order <- forAll (Gen.shuffle ([1, 2, 3] :: [Int]))
    let byId n = case n of
          1 -> mkTestMessage 1 [] (Just "a")
          2 -> mkTestMessage 2 ["a"] (Just "b")
          _ -> mkTestMessage 3 ["a", "b"] (Just "c")
        shuffled = map byId order
        baseline = map byId ([1, 2, 3] :: [Int])
    case (threadMessages testAccount (NE.fromList baseline), threadMessages testAccount (NE.fromList shuffled)) of
      (Right f1, Right f2) -> f1 === f2
      (Left err, _)        -> fail ("baseline threading failed: " <> show err)
      (_, Left err)        -> fail ("shuffled threading failed: " <> show err)
