module Owl.Store.SQLiteSpec (spec) where

import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Test.Hspec

import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Attachment (Attachment (..))
import qualified Owl.Domain.Body as BodyT
import Owl.Domain.Flag (Flag (..))
import Owl.Domain.Id (AccountId (..), LocalId (..), MessageId (..), ThreadId (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (mkSubject)
import Owl.Message.Identity (MessageIdentity (..), ValidatedRfcId, parseRfcMessageId)
import Owl.Message.Types (Message (..))
import Owl.Search.Predicate (Predicate (..))
import Owl.Store.SQLite
import Owl.Store.Types

mkAddr :: Text -> Address
mkAddr t = Address Nothing (either (error . show) id (mkEmailAddress t))

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

mustRfc :: Text -> ValidatedRfcId
mustRfc t = maybe (error "bad fixture rfc id") id (parseRfcMessageId ("<" <> t <> "@example.com>"))

mkMsg :: Int -> Message
mkMsg n = Message
  { identity    = MessageIdentity { messageId = mkMid n, rfcId = Just (AccountId "acct", mustRfc "abc") }
  , accountId   = AccountId "acct"
  , threadId    = ThreadId "t1"
  , sender      = Address (Just "Alice Smith") (either (error . show) id (mkEmailAddress "alice@example.com"))
  , recipients  = [mkAddr "bob@example.net"]
  , subject     = either (error . show) id (mkSubject "Hello")
  , sentAt      = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
  , body        = BodyT.Body (Just "hello world") Nothing
  , attachments = [Attachment (Just "file.txt") "text/plain" "abcxyz"]
  , flags       = Set.fromList [Seen, Flagged]
  , references  = []
  , replyTo    = []
  }

spec :: Spec
spec = describe "Owl.Store.SQLite" $ do
  it "opens a fresh in-memory database with the current schema version" $ do
    result <- openSQLiteStore ":memory:"
    case result of
      Left err -> expectationFailure (show err)
      Right _  -> pure ()

  it "returns MessageNotFound for a message that was never saved" $ do
    Right store <- openSQLiteStore ":memory:"
    result <- loadMessage store (mkMid 1)
    result `shouldBe` Left (MessageNotFound (mkMid 1))

  it "round-trips a saved message exactly, including recipients/flags/attachments/rfcId" $ do
    Right store <- openSQLiteStore ":memory:"
    let msg = mkMsg 1
    saveResult <- saveMessage store msg
    saveResult `shouldBe` Right ()
    loadResult <- loadMessage store (mkMid 1)
    loadResult `shouldBe` Right msg

  it "finds a saved message via searchMessages" $ do
    Right store <- openSQLiteStore ":memory:"
    let msg = mkMsg 1
    _ <- saveMessage store msg
    result <- searchMessages store (SubjectContains "Hello")
    result `shouldBe` Right (Set.singleton (mkMid 1))
