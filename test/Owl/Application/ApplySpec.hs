module Owl.Application.ApplySpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Test.Hspec

import qualified Owl.Domain.Body as BodyT
import Owl.AddressBook
import Owl.Application
import Owl.Application.Apply
import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Flag (Flag (..))
import Owl.Domain.Id (AccountId (..), LocalId (..), MailboxId (..), MessageId (..), PersonId (..), ThreadId (..))
import Owl.Domain.MailAddress (Address (..))
import Owl.Domain.Person (Person (..))
import Owl.Domain.Subject (mkSubject)
import Owl.Event
import Owl.Message.Identity (MessageIdentity (..))
import Owl.Message.Types (Message (..))
import Owl.Search.Predicate (MailMembership (..))

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
  , body        = BodyT.Body (Just "hello world") Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = []
  , replyTo    = []
  }

receiveMsg :: Int -> Application -> Either DomainError Application
receiveMsg n app = apply (MessageReceived (mkMsg n)) app

-- | emptyApplication with message 1 already received -- the common
-- starting point for tests that need a known message present.
withMsg1 :: Application
withMsg1 = either (error . show) id (receiveMsg 1 emptyApplication)

spec :: Spec
spec = do
  describe "apply MessageReceived" $ do
    it "adds the message to MessageState and ThreadState" $ do
      let MessageState msgs _ _ = messages withMsg1
          ThreadState tmap      = threads withMsg1
      msgs `shouldBe` Map.singleton (mkMid 1) (mkMsg 1)
      tmap `shouldBe` Map.singleton (ThreadId "t1") (Set.singleton (mkMid 1))

    it "rejects receiving the same MessageId twice" $
      receiveMsg 1 withMsg1 `shouldBe` Left (DuplicateMessage (mkMid 1))

  describe "apply MessageRead / MessageUnread" $ do
    it "adds the Seen flag on MessageRead" $ do
      case apply (MessageRead (mkMid 1)) withMsg1 of
        Left err  -> expectationFailure (show err)
        Right app ->
          let MessageState msgs _ _ = messages app
          in flags (msgs Map.! mkMid 1) `shouldBe` Set.singleton Seen

    it "removes the Seen flag on MessageUnread" $ do
      case apply (MessageRead (mkMid 1)) withMsg1 of
        Left err        -> expectationFailure (show err)
        Right afterRead -> case apply (MessageUnread (mkMid 1)) afterRead of
          Left err  -> expectationFailure (show err)
          Right app ->
            let MessageState msgs _ _ = messages app
            in flags (msgs Map.! mkMid 1) `shouldBe` Set.empty

    it "fails with UnknownMessage for a message never received" $
      apply (MessageRead (mkMid 99)) emptyApplication `shouldBe` Left (UnknownMessage (mkMid 99))

  describe "apply MessageArchived / Unarchived / Deleted / Restored" $ do
    it "tracks archived status as its own relation, separate from Message.flags" $ do
      case apply (MessageArchived (mkMid 1)) withMsg1 of
        Left err -> expectationFailure (show err)
        Right archivedApp -> do
          archivedMessages (messages archivedApp) `shouldBe` Set.singleton (mkMid 1)
          case apply (MessageUnarchived (mkMid 1)) archivedApp of
            Left err  -> expectationFailure (show err)
            Right app -> archivedMessages (messages app) `shouldBe` Set.empty

    it "soft-deletes without removing the message from MessageState" $ do
      case apply (MessageDeleted (mkMid 1)) withMsg1 of
        Left err -> expectationFailure (show err)
        Right deletedApp -> do
          deletedMessages (messages deletedApp) `shouldBe` Set.singleton (mkMid 1)
          let MessageState msgs _ _ = messages deletedApp
          Map.member (mkMid 1) msgs `shouldBe` True
          case apply (MessageRestored (mkMid 1)) deletedApp of
            Left err  -> expectationFailure (show err)
            Right app -> deletedMessages (messages app) `shouldBe` Set.empty

  describe "apply MessageMoved / MessageLabeled / MessageUnlabeled" $ do
    it "MessageMoved adds membership in dst and removes it from src" $ do
      let step1 = apply (MessageLabeled (mkMid 1) (MailboxId "inbox")) withMsg1
      case step1 >>= apply (MessageMoved (mkMid 1) (MailboxId "inbox") (MailboxId "archive")) of
        Left err  -> expectationFailure (show err)
        Right app ->
          let MailMembership m = membership (mailboxes app)
          in m `shouldBe` Map.singleton (mkMid 1) (Set.singleton (MailboxId "archive"))

    it "MessageUnlabeled removes exactly the one named mailbox" $ do
      let steps = apply (MessageLabeled (mkMid 1) (MailboxId "inbox")) withMsg1
            >>= apply (MessageLabeled (mkMid 1) (MailboxId "work"))
            >>= apply (MessageUnlabeled (mkMid 1) (MailboxId "inbox"))
      case steps of
        Left err  -> expectationFailure (show err)
        Right app ->
          let MailMembership m = membership (mailboxes app)
          in m `shouldBe` Map.singleton (mkMid 1) (Set.singleton (MailboxId "work"))

  describe "apply ContactChanged" $
    it "adds a new contact to ContactState" $ do
      let person = Person
            { personId           = PersonId "p1"
            , personName         = Just "Alice"
            , personEmails       = either (error . show) id (mkEmailAddress "alice@example.com") :| []
            , personOrganization = Nothing
            , personPhone        = Nothing
            , personGroups       = Set.empty
            , personNotes        = Nothing
            , personAliases      = Set.empty
            }
          contact = Contact person (Set.singleton FromSavedContact) Nothing 0
      case apply (ContactChanged contact) emptyApplication of
        Left err  -> expectationFailure (show err)
        Right app ->
          let ContactState book = contacts app
          in Map.keys (abContacts book) `shouldBe` [PersonId "p1"]

  describe "apply DraftCreated / DraftChanged / MessageSent (honest no-ops pending §21)" $
    it "MessageSent is a no-op that still requires a known MessageId" $ do
      apply (MessageSent (mkMid 1)) withMsg1 `shouldBe` Right withMsg1
      apply (MessageSent (mkMid 99)) emptyApplication `shouldBe` Left (UnknownMessage (mkMid 99))

  describe "markRead / archive / moveMessage / sendDraft (total, no Either)" $ do
    it "markRead is a no-op on an unknown message rather than erroring" $
      markRead (mkMid 99) emptyApplication `shouldBe` emptyApplication

    it "markRead on a known message matches apply's Right case" $
      case apply (MessageRead (mkMid 1)) withMsg1 of
        Left err       -> expectationFailure (show err)
        Right expected -> markRead (mkMid 1) withMsg1 `shouldBe` expected

  describe "invertEvent / undo" $ do
    it "MessageRead inverts to MessageUnread and vice versa" $ do
      invertEvent (MessageRead (mkMid 1)) `shouldBe` Just (MessageUnread (mkMid 1))
      invertEvent (MessageUnread (mkMid 1)) `shouldBe` Just (MessageRead (mkMid 1))

    it "MessageReceived has no inverse" $
      invertEvent (MessageReceived (mkMsg 1)) `shouldBe` Nothing

    it "undo restores the prior state after markRead" $ do
      let stack = pushUndo (MessageRead (mkMid 1)) emptyUndoStack
      case apply (MessageRead (mkMid 1)) withMsg1 of
        Left err        -> expectationFailure (show err)
        Right afterRead -> case undo stack afterRead of
          Left err            -> expectationFailure (show err)
          Right (restored, _) -> restored `shouldBe` withMsg1

    it "undo on an empty stack is a no-op" $
      undo emptyUndoStack withMsg1 `shouldBe` Right (withMsg1, emptyUndoStack)
