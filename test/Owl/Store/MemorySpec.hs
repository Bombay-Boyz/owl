module Owl.Store.MemorySpec (spec) where

import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Test.Hspec

import Owl.Compose (Draft (..))
import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Body (Body (..))
import Owl.Domain.Id (AccountId (..), LocalId (..), MessageId (..), ThreadId (..))
import Owl.Domain.Identity (Identity (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Subject (mkSubject)
import Owl.Message.Identity (MessageIdentity (..))
import Owl.Message.Types (Message (..))
import Owl.Store.Memory
import Owl.Store.Types

mkAddr :: Text -> Address
mkAddr t = Address Nothing (either (error . show) id (mkEmailAddress t))

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

mkMsg :: Int -> Message
mkMsg n = Message
  { identity    = MessageIdentity { messageId = mkMid n, rfcId = Nothing }
  , accountId   = AccountId "acct"
  , threadId    = ThreadId "t1"
  , sender      = mkAddr "alice@example.com"
  , recipients  = [mkAddr "bob@example.net"]
  , subject     = either (error . show) id (mkSubject "Hello")
  , sentAt      = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
  , body        = Body (Just "hello world") Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = []
  , replyTo    = []
  }

spec :: Spec
spec = do
  messageSpec
  draftSpec

messageSpec :: Spec
messageSpec = describe "Owl.Store.Memory (messages)" $ do
  it "returns MessageNotFound for a message that was never saved" $ do
    store  <- newMemoryStore
    result <- loadMessage store (mkMid 1)
    result `shouldBe` Left (MessageNotFound (mkMid 1))

  it "round-trips a saved message exactly" $ do
    store <- newMemoryStore
    let msg = mkMsg 1
    saveResult <- saveMessage store msg
    saveResult `shouldBe` Right ()
    loadResult <- loadMessage store (mkMid 1)
    loadResult `shouldBe` Right msg

  it "overwrites a message saved twice under the same MessageId" $ do
    store <- newMemoryStore
    let msg1 = mkMsg 1
        msg2 = msg1 { subject = either (error . show) id (mkSubject "Updated") }
    _ <- saveMessage store msg1
    _ <- saveMessage store msg2
    loadResult <- loadMessage store (mkMid 1)
    loadResult `shouldBe` Right msg2


mkTestIdentity :: Address -> Identity
mkTestIdentity (Address _ email) = Identity
  { identityAccountId    = AccountId "acct"
  , identityEmailAddress = email
  , identityDisplayName  = Nothing
  , identityIsDefault    = True
  }

mkDraft :: Int -> Draft
mkDraft n = Draft
  { draftId            = mkMid n
  , draftIdentity      = mkTestIdentity (mkAddr "alice@example.com")
  , draftRecipients    = [mkAddr "bob@example.net"]
  , draftSubject       = either (error . show) id (mkSubject "Draft subject")
  , draftBody          = Body (Just "draft body") Nothing
  , draftAttachments   = []
  , draftThreadHeaders = Nothing
  }

draftSpec :: Spec
draftSpec = describe "Owl.Store.Memory (drafts)" $ do
  it "returns DraftNotFound for a draft that was never saved" $ do
    store  <- newMemoryStore
    result <- loadDraft store (mkMid 1)
    result `shouldBe` Left (DraftNotFound (mkMid 1))

  it "round-trips a saved draft exactly" $ do
    store <- newMemoryStore
    let draft = mkDraft 1
    saveResult <- saveDraft store draft
    saveResult `shouldBe` Right ()
    loadResult <- loadDraft store (mkMid 1)
    loadResult `shouldBe` Right draft

  it "removes a draft on deleteDraft" $ do
    store <- newMemoryStore
    _ <- saveDraft store (mkDraft 1)
    _ <- deleteDraft store (mkMid 1)
    loadResult <- loadDraft store (mkMid 1)
    loadResult `shouldBe` Left (DraftNotFound (mkMid 1))

  it "listDrafts reflects saved and deleted drafts" $ do
    store <- newMemoryStore
    _ <- saveDraft store (mkDraft 1)
    _ <- saveDraft store (mkDraft 2)
    afterSaves <- listDrafts store
    afterSaves `shouldBe` Right [mkMid 1, mkMid 2]
    _ <- deleteDraft store (mkMid 1)
    afterDelete <- listDrafts store
    afterDelete `shouldBe` Right [mkMid 2]
