module Owl.ComposeSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Hedgehog (forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Owl.Compose hiding (replyTo)
import qualified Owl.Compose as Compose
import Owl.Domain.Address (mkEmailAddress)
import Owl.Domain.Body (Body (..))
import Owl.Domain.Id (AccountId (..), LocalId (..), MessageId (..), ThreadId (..))
import Owl.Domain.Identity (Identity (..))
import Owl.Domain.MailAddress (Address (..), addressEmail)
import Owl.Domain.Subject (Subject, mkSubject, unSubject)
import Owl.Domain.Attachment (Attachment (..), AttachmentLimits (..))
import Owl.Message.Boundary (decodeCharset, parseMessage, toMessage, validateMessage)
import Owl.Message.Identity (MessageIdentity (..), ValidatedRfcId, parseRfcMessageId)
import Owl.Message.Types (Message (..))

-- A fixed instant, so rendered bytes are deterministic across runs.
testLimits :: AttachmentLimits
testLimits = AttachmentLimits
  { maxAttachmentCount     = 10
  , maxAttachmentTotalSize = 10 * 1024 * 1024
  }

testNow :: UTCTime
testNow = UTCTime (fromGregorian 2026 1 15) (secondsToDiffTime (14 * 3600 + 30 * 60 + 5))

mkAddr :: Text -> Address
mkAddr t = Address Nothing (either (error . show) id (mkEmailAddress t))

mkMid :: Int -> MessageId
mkMid n = MessageId (LocalId (UUID.fromWords (fromIntegral n) 0 0 0))

mkSub :: Text -> Subject
mkSub t = either (error . show) id (mkSubject t)

mustRfc :: Text -> ValidatedRfcId
mustRfc t = maybe (error "bad fixture rfc") id (parseRfcMessageId ("<" <> t <> "@example.com>"))

testIdentity :: Identity
testIdentity = Identity
  { identityAccountId    = AccountId "acct1"
  , identityEmailAddress = either (error . show) id (mkEmailAddress "alice@example.com")
  , identityDisplayName  = Just "Alice Smith"
  , identityIsDefault    = True
  }

otherAccountIdentity :: Identity
otherAccountIdentity = testIdentity { identityAccountId = AccountId "acct2" }

originalMsg :: Message
originalMsg = Message
  { identity    = MessageIdentity
      { messageId = mkMid 1
      , rfcId     = Just (AccountId "acct1", mustRfc "orig")
      }
  , accountId   = AccountId "acct1"
  , threadId    = ThreadId "t1"
  , sender      = mkAddr "bob@example.net"
  , recipients  = [mkAddr "alice@example.com", mkAddr "carol@example.org"]
  , subject     = mkSub "Project update"
  , sentAt      = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
  , body        = Body (Just "line one\nline two") Nothing
  , attachments = []
  , flags       = Set.empty
  , references  = []
  , replyTo     = []
  }

originalWithReplyTo :: Message
originalWithReplyTo = originalMsg { replyTo = [mkAddr "list@example.org"] }

spec :: Spec
spec = do
  describe "normalizeReplySubject" $ do
    it "adds Re: to a bare subject" $
      unSubject (normalizeReplySubject (mkSub "Hello")) `shouldBe` "Re: Hello"

    it "does not double up an existing Re:" $
      unSubject (normalizeReplySubject (mkSub "Re: Hello")) `shouldBe` "Re: Hello"

    it "collapses a doubled Re: Re:" $
      unSubject (normalizeReplySubject (mkSub "Re: Re: Hello")) `shouldBe` "Re: Hello"

    it "is case-insensitive on the existing prefix" $
      unSubject (normalizeReplySubject (mkSub "RE: Hello")) `shouldBe` "Re: Hello"

    it "is idempotent for any generated subject text" $ hedgehog $ do
      text <- forAll (Gen.text (Range.linear 0 40) (Gen.filter (`notElem` ("\r\n" :: String)) Gen.unicode))
      case mkSubject text of
        Left _     -> pure ()
        Right subj ->
          let once  = normalizeReplySubject subj
              twice = normalizeReplySubject once
          in unSubject twice === unSubject once

  describe "threadHeaders" $ do
    it "carries the original's own rfcId as In-Reply-To and appends it to References" $ do
      let hdrs = threadHeaders originalMsg
      (() <$ headersInReplyTo hdrs) `shouldBe` Just ()
      length (headersReferences hdrs) `shouldBe` 1

    it "is Nothing/empty when the original has no known rfcId" $ do
      let noRfc = originalMsg { identity = (identity originalMsg) { rfcId = Nothing } }
          hdrs  = threadHeaders noRfc
      headersInReplyTo hdrs `shouldBe` Nothing
      headersReferences hdrs `shouldBe` []

  describe "replyTo" $ do
    it "ReplyToSender replies only to the sender" $
      case Compose.replyTo (mkMid 2) ReplyToSender testIdentity originalMsg of
        Left err    -> expectationFailure (show err)
        Right draft -> draftRecipients draft `shouldBe` [sender originalMsg]

    it "ReplyToAll includes other recipients but excludes the identity's own address" $
      case Compose.replyTo (mkMid 2) ReplyToAll testIdentity originalMsg of
        Left err    -> expectationFailure (show err)
        Right draft -> draftRecipients draft `shouldBe` [sender originalMsg, mkAddr "carol@example.org"]

    it "prefers Reply-To over the sender when present (also covers mailing-list behavior)" $
      case Compose.replyTo (mkMid 2) ReplyToSender testIdentity originalWithReplyTo of
        Left err    -> expectationFailure (show err)
        Right draft -> draftRecipients draft `shouldBe` [mkAddr "list@example.org"]

    it "normalizes the subject and quotes the body" $
      case Compose.replyTo (mkMid 2) ReplyToSender testIdentity originalMsg of
        Left err    -> expectationFailure (show err)
        Right draft -> do
          unSubject (draftSubject draft) `shouldBe` "Re: Project update"
          bodyPlainText (draftBody draft) `shouldBe` Just "> line one\n> line two\n"

    it "rejects an identity from a different account than the message" $
      Compose.replyTo (mkMid 2) ReplyToSender otherAccountIdentity originalMsg
        `shouldBe` Left (IdentityAccountMismatch (AccountId "acct2") (AccountId "acct1"))

  describe "quoteBody" $
    it "QuoteNone empties the body" $
      quoteBody QuoteNone (Body (Just "hi") Nothing) `shouldBe` Body Nothing Nothing

  describe "toEnvelope" $ do
    it "rejects a Draft with no recipients" $
      toEnvelope testNow (newDraft (mkMid 3) testIdentity (mkSub "Hi")) `shouldBe` Left NoRecipients

    it "builds an envelope with the identity's address as From and all recipients as To" $ do
      let draft = (newDraft (mkMid 3) testIdentity (mkSub "Hi"))
            { draftRecipients = [mkAddr "bob@example.net", mkAddr "carol@example.org"] }
      case toEnvelope testNow draft of
        Left err       -> expectationFailure (show err)
        Right envelope -> do
          addressEmail (envelopeSender envelope) `shouldBe` identityEmailAddress testIdentity
          NE.toList (envelopeRecipients envelope)
            `shouldBe` [mkAddr "bob@example.net", mkAddr "carol@example.org"]

    it "renders wire bytes that purebred-email's own parser accepts" $ do
      let draft = (newDraft (mkMid 3) testIdentity (mkSub "Hi there"))
            { draftRecipients = [mkAddr "bob@example.net"]
            , draftBody       = Body (Just "hello") Nothing
            }
      case toEnvelope testNow draft of
        Left err       -> expectationFailure (show err)
        Right envelope -> case parseMessage (envelopePayload envelope) of
          Left _  -> expectationFailure "rendered payload did not parse"
          Right _ -> pure ()

  -- These assert on the actual rendered BYTES, not on the envelope's
  -- structured fields. That distinction is the whole point: the
  -- envelope carried thread headers correctly for some time while
  -- renderDraft silently ignored them, and every structural test
  -- passed throughout. Only dumping the bytes revealed it.
  describe "outgoing header audit -- asserts on rendered bytes" $ do
    let simpleDraft = (newDraft (mkMid 3) testIdentity (mkSub "Hi there"))
          { draftRecipients = [mkAddr "bob@example.net"]
          , draftBody       = Body (Just "hello") Nothing
          }

        payloadOf draft = case toEnvelope testNow draft of
          Left err       -> Left (show err)
          Right envelope -> Right (envelopePayload envelope)

        shouldContainBytes label needle draft =
          case payloadOf draft of
            Left err      -> expectationFailure (label ++ ": " ++ err)
            Right payload ->
              if needle `BC.isInfixOf` payload
                then pure ()
                else expectationFailure
                       (label ++ ": expected " ++ show needle
                        ++ " in rendered payload:\n" ++ BC.unpack payload)

    it "emits a Message-ID" $
      shouldContainBytes "Message-ID header" "Message-ID:" simpleDraft

    it "emits a Message-ID of the form <uuid@sender-domain>" $
      -- mkMid 3 is UUID.fromWords 3 0 0 0, so the exact text is known.
      shouldContainBytes "exact Message-ID"
        "<00000003-0000-0000-0000-000000000000@example.com>" simpleDraft

    it "does NOT leak a hostname in the Message-ID (docs/header-privacy.md R1)" $
      case payloadOf simpleDraft of
        Left err      -> expectationFailure err
        Right payload -> do
          -- The right-hand side must be the sender's mail domain and
          -- nothing else -- no .local, no machine name.
          (".local" `BC.isInfixOf` payload) `shouldBe` False
          ("localhost" `BC.isInfixOf` payload) `shouldBe` False

    it "emits no User-Agent or X-Mailer (docs/header-privacy.md R2)" $
      case payloadOf simpleDraft of
        Left err      -> expectationFailure err
        Right payload -> do
          ("User-Agent" `BC.isInfixOf` payload) `shouldBe` False
          ("X-Mailer" `BC.isInfixOf` payload) `shouldBe` False

    it "emits In-Reply-To for a reply, pointing at the original" $
      case Compose.replyTo (mkMid 4) ReplyToSender testIdentity originalMsg of
        Left err    -> expectationFailure (show err)
        Right draft -> do
          shouldContainBytes "In-Reply-To header" "In-Reply-To:" draft
          shouldContainBytes "original message id" "orig@example.com" draft

    it "emits References for a reply" $
      case Compose.replyTo (mkMid 4) ReplyToSender testIdentity originalMsg of
        Left err    -> expectationFailure (show err)
        Right draft -> shouldContainBytes "References header" "References:" draft

    it "emits no In-Reply-To for a fresh compose" $
      case payloadOf simpleDraft of
        Left err      -> expectationFailure err
        Right payload -> ("In-Reply-To" `BC.isInfixOf` payload) `shouldBe` False

    it "emits a Date header" $
      shouldContainBytes "Date header" "Date:" simpleDraft

    -- The gap this replaces asserted Date was ABSENT, deliberately, so
    -- the documentation could not rot silently. Its failure was the
    -- signal to write this.
    it "emits a Date in UTC, never the local zone (docs/header-privacy.md R3)" $
      shouldContainBytes "UTC offset" "+0000" simpleDraft

    it "embeds attachments as multipart/mixed" $ do
      let withAtt = simpleDraft
            { draftAttachments =
                [ Attachment (Just "notes.txt") "text/plain" "file contents here" ]
            }
      shouldContainBytes "multipart content type" "multipart/mixed" withAtt
      shouldContainBytes "attachment disposition" "attachment" withAtt
      shouldContainBytes "filename parameter" "notes.txt" withAtt

    it "stays single-part when there is nothing to attach" $
      case payloadOf simpleDraft of
        Left err      -> expectationFailure err
        Right payload -> ("multipart" `BC.isInfixOf` payload) `shouldBe` False

    it "uses a boundary derived from the draft's UUID, not a random one" $
      -- mkMid 3 is UUID.fromWords 3 0 0 0, so this is deterministic --
      -- the same draft renders byte-identically every time, which a
      -- randomly-generated boundary would not.
      shouldContainBytes "derived boundary"
        "owl-00000003-0000-0000-0000-000000000000"
        simpleDraft { draftAttachments = [Attachment (Just "a.txt") "text/plain" "x"] }

    it "attachment round-trip: an attached file survives render and re-parse" $ do
      let withAtt = simpleDraft
            { draftAttachments =
                [ Attachment (Just "notes.txt") "text/plain" "file contents here" ]
            }
      case toEnvelope testNow withAtt of
        Left err  -> expectationFailure (show err)
        Right env -> case parseMessage (envelopePayload env) of
          Left _    -> expectationFailure "multipart payload did not parse"
          Right raw -> case decodeCharset raw of
            Left _    -> expectationFailure "multipart payload did not decode"
            Right dec ->
              case validateMessage (AccountId "acct1") (mkMid 9) testLimits dec of
                Left err -> expectationFailure ("multipart failed validation: " ++ show err)
                Right vm -> do
                  let recovered = attachments (toMessage vm)
                  map attachmentContent recovered `shouldBe` ["file contents here"]
                  map attachmentFilename recovered `shouldBe` [Just "notes.txt"]

    it "falls back to octet-stream for an unparseable stored MIME type, \
       \rather than dropping the attachment" $ do
      let weird = simpleDraft
            { draftAttachments =
                [ Attachment (Just "x.bin") "this is not a mime type" "data" ]
            }
      shouldContainBytes "fallback type" "application/octet-stream" weird

    it "can parse back a date it wrote itself -- round-trips through our own parser" $
      case toEnvelope testNow simpleDraft of
        Left err  -> expectationFailure (show err)
        Right env -> case parseMessage (envelopePayload env) of
          Left _    -> expectationFailure "own rendered payload did not parse"
          Right raw -> case decodeCharset raw of
            Left _    -> expectationFailure "own rendered payload did not decode"
            Right dec ->
              case validateMessage (AccountId "acct1") (mkMid 9) testLimits dec of
                Left err  -> expectationFailure ("own message failed validation: " ++ show err)
                Right vm  -> sentAt (toMessage vm) `shouldBe` testNow
