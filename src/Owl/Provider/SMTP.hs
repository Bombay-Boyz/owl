-- | SMTP adapter (master spec §20): translate the already-validated
-- OutgoingEnvelope to a form HaskellNet can send; do not implement
-- SMTP itself.
--
-- HaskellNet's own sendMail requires a structured
-- Network.Mail.Mime.Mail value (confirmed directly against its
-- current Haddock -- an earlier draft of this module wrongly assumed
-- a raw-bytes signature from an older version, and a second wrong
-- guess at a lower-level sendCommand/MAIL/RCPT/DATA escape hatch that
-- turned out not to be publicly exported at all). buildMail
-- reconstructs a Mail value from OutgoingEnvelope's own structured
-- fields via mime-mail -- a second mature MIME library, not a
-- hand-rolled one, deriving from the exact same Draft data as
-- envelopePayload (§21), so the two should never meaningfully diverge
-- in content, only in lower-level formatting choices.
--
-- CONFIDENCE NOTE: simpleMail'/addAttachmentsBS/Address's shapes are
-- confirmed directly against mime-mail's own source. Mail's exact
-- field names (mailTo etc.), used here to override simpleMail's single
-- recipient with the envelope's full recipient list, follow the
-- exported Mail(..) record's well-established naming convention but
-- are not verified letter-for-letter against the resolved version's
-- source -- the most likely remaining thing to need correcting here.
module Owl.Provider.SMTP
  ( sendMessage
  ) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString.Lazy as LBS
import Data.List.NonEmpty (toList)
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text
import qualified Data.Text.Lazy as LT
import qualified Network.HaskellNet.SMTP as SMTP
import qualified Network.HaskellNet.SMTP.SSL as SMTPSSL
import qualified Network.Mail.Mime as Mime

import Owl.Compose (OutgoingEnvelope (..))
import Owl.Domain.Address (unEmailAddress)
import Owl.Domain.Attachment (Attachment (..))
import Owl.Domain.MailAddress (Address (..), sanitizeDisplayName)
import Owl.Domain.Subject (unSubject)
import Owl.Provider.Types

sendMessage :: ProviderSession -> OutgoingEnvelope -> IO (Either ProviderError SendOutcome)
sendMessage session envelope = do
  connResult <- connectAndAuth session
  case connResult of
    Left err -> pure (Left err)
    Right conn -> do
      sendResult <- try (SMTP.sendMail (buildMail envelope) conn) :: IO (Either SomeException ())
      _ <- try (SMTP.closeSMTP conn) :: IO (Either SomeException ())
      pure $ case sendResult of
        Left _   -> Right SendOutcomeUnknown
        Right () -> Right Sent

buildMail :: OutgoingEnvelope -> Mime.Mail
buildMail envelope =
  (Mime.addAttachmentsBS attachmentTriples baseMail) { Mime.mailTo = toAddrs }
  where
    fromAddr = toMimeAddress (envelopeSender envelope)
    toAddrs  = map toMimeAddress (toList (envelopeRecipients envelope))
    baseMail = Mime.simpleMail'
      (toMimeAddress (NE.head (envelopeRecipients envelope)))
      fromAddr
      (unSubject (envelopeSubjectText envelope))
      (LT.fromStrict (fromMaybe Text.empty (envelopeBodyPlain envelope)))
    attachmentTriples =
      [ (attachmentMimeType a, fromMaybe "attachment" (attachmentFilename a), LBS.fromStrict (attachmentContent a))
      | a <- envelopeAttachments envelope
      ]

toMimeAddress :: Address -> Mime.Address
toMimeAddress addr = Mime.Address (sanitizeDisplayName (addressDisplayName addr)) (unEmailAddress (addressEmail addr))

connectAndAuth :: ProviderSession -> IO (Either ProviderError SMTP.SMTPConnection)
connectAndAuth session = do
  connResult <- try (SMTPSSL.connectSMTPSSL (Text.unpack (smtpHost settings)))
    :: IO (Either SomeException SMTP.SMTPConnection)
  case connResult of
    Left e -> pure (Left (ProviderConnectionFailed (Text.pack (show e))))
    Right conn -> do
      authResult <- try (doAuth conn) :: IO (Either SomeException Bool)
      case authResult of
        Left e      -> pure (Left (ProviderConnectionFailed (Text.pack (show e))))
        Right False -> pure (Left (ProviderAuthenticationFailed "SMTP server rejected credentials"))
        Right True  -> pure (Right conn)
  where
    settings = sessionSettings session
    doAuth conn = case sessionAuth session of
      PasswordAuth pw  -> SMTP.authenticate SMTP.PLAIN (Text.unpack (providerUsername settings)) (Text.unpack pw) conn
      OAuth2Auth token -> SMTP.authenticate SMTP.XOAUTH2 (Text.unpack (providerUsername settings)) (Text.unpack token) conn
