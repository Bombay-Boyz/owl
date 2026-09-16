-- | The message boundary (master spec §12): Bytes -> RFC/MIME parser ->
-- RawMessage -> charset-decode -> normalize -> ValidatedMessage -> Owl
-- Message. Uses purebred-email for RFC 5322/MIME parsing, per §12's
-- "use mature MIME/RFC libraries" rule -- purebred-email is
-- AGPL-3.0-or-later, and Owl is licensed the same way as a direct,
-- deliberate consequence (see LICENSE).
--
-- Data.IMF and Data.MIME are imported fully qualified throughout --
-- both export names that collide head-on with Owl's own vocabulary
-- (their own Address type; body and attachments optics matching
-- Message's own field names) -- qualifying avoids all of it rather
-- than working around it name-by-name.
--
-- Two deliberate, documented deviations from the master spec's literal
-- four signatures, both for the same underlying reason: something the
-- pure pipeline cannot conjure itself must come from the effectful
-- caller (§20's provider adapter).
--   * accountId -- genuinely known before any byte is parsed.
--   * a fresh MessageId -- minting Owl's own identity (§13) means
--     generating a random UUID, which is an effect; validateMessage
--     itself must stay pure. threadId needed no such deviation --
--     Owl.Message.Identity.singletonThreadId derives it purely.
-- toMessage itself is completely untouched, exactly as given.
module Owl.Message.Boundary
  ( RawMessage
  , DecodedMessage
  , ValidatedMessage
  , ParseError (..)
  , CharsetError (..)
  , parseMessage
  , parseMessageWithLimit
  , maxRawMessageSize
  , decodeCharset
  , validateMessage
  , toMessage
  ) where

import Control.Applicative ((<|>))
import Control.Lens (filtered, firstOf, preview, to, toListOf, view, _Just, _Right)
import Data.Attoparsec.ByteString (parseOnly)
import Data.ByteString (ByteString)
import qualified Data.CaseInsensitive as CI
import qualified Data.ByteString as ByteString
import Data.Foldable (toList)
import qualified Data.IMF as IMF
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.MIME as MIME
import qualified Data.MIME.Charset as Charset
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import Owl.Domain.Attachment (Attachment (..), AttachmentLimits, validateAttachments)
import Owl.Domain.Address (AddressError, mkEmailAddress)
import Owl.Domain.Body (Body (..), SanitizedHtml, sanitizeHtml)
import Owl.Domain.Id (AccountId, MessageId)
import qualified Owl.Domain.MailAddress as Owl
import Owl.Domain.MailAddress (sanitizeDisplayName)
import Owl.Domain.MessageError (MessageError (..))
import Owl.Domain.Subject (Subject, mkSubject)
import Owl.Message.Identity (MessageIdentity (..), ValidatedRfcId, parseRfcMessageId, singletonThreadId)
import Owl.Message.Types (Message (..))

newtype RawMessage = RawMessage MIME.MIMEMessage

newtype ParseError = ParseError Text
  deriving stock (Eq, Show)

-- | Maximum raw message size we're willing to parse at all (§12's
-- own boundary discipline: reject clearly-pathological input before
-- doing any real work, rather than trying to process it defensively).
-- Chosen well above any real message a legitimate mail server would
-- ever send (Gmail's own limit is 25MB for the whole message
-- including attachments), while still bounding worst-case resource use
-- from a maliciously crafted message -- including one using excessive
-- MIME nesting rather than large attachments. A direct nesting-depth
-- count was considered and deliberately rejected: computing it would
-- require traversing the very tree structure whose traversal might be
-- unsafe on a pathological input, which defeats the point. A size
-- limit sidesteps that circularity -- each nesting level requires real
-- bytes of boundary/header overhead (at minimum ~60-100 bytes per
-- level), so bounding total size already caps nesting depth to
-- something far below what would exhaust a stack in practice.
maxRawMessageSize :: Int
maxRawMessageSize = 50 * 1024 * 1024  -- 50 MB

parseMessage :: ByteString -> Either ParseError RawMessage
parseMessage = parseMessageWithLimit maxRawMessageSize

-- | Exposed separately from parseMessage so the size-rejection path
-- itself is testable without constructing an actual 50MB ByteString.
parseMessageWithLimit :: Int -> ByteString -> Either ParseError RawMessage
parseMessageWithLimit limit raw
  | ByteString.length raw > limit =
      Left (ParseError (Text.pack ("message exceeds maximum size of " ++ show limit ++ " bytes")))
  | otherwise = case parseOnly (IMF.message MIME.mime) raw of
      Left err  -> Left (ParseError (Text.pack err))
      Right msg -> Right (RawMessage msg)

newtype DecodedMessage = DecodedMessage MIME.MIMEMessage

newtype CharsetError = CharsetError Text
  deriving stock (Eq, Show)

decodeCharset :: RawMessage -> Either CharsetError DecodedMessage
decodeCharset (RawMessage m) = Right (DecodedMessage m)

newtype ValidatedMessage = ValidatedMessage Message

validateMessage
  :: AccountId
  -> MessageId
  -> AttachmentLimits
  -> DecodedMessage
  -> Either MessageError ValidatedMessage
validateMessage acct mid limits (DecodedMessage mimeMsg) = do
  senderAddr     <- extractSender mimeMsg
  recipientAddrs <- extractRecipients mimeMsg
  subj           <- extractSubject mimeMsg
  sentAtValue    <- extractSentAt mimeMsg
  attachmentList <- either (Left . MessageAttachmentsInvalid) Right
                       (validateAttachments limits (extractAttachments mimeMsg))
  let identityValue = MessageIdentity
        { messageId = mid
        , rfcId     = (,) acct <$> extractRfcId mimeMsg
        }
      (plainText, htmlText) = extractBody mimeMsg
      msg = Message
        { identity    = identityValue
        , accountId   = acct
        , threadId    = singletonThreadId mid
        , sender      = senderAddr
        , recipients  = recipientAddrs
        , subject     = subj
        , sentAt      = sentAtValue
        , body        = Body { bodyPlainText = plainText, bodyHtml = htmlText }
        , attachments = attachmentList
        , flags       = Set.empty
        , references  = extractReferences mimeMsg
        , replyTo     = extractReplyTo mimeMsg
        }
  pure (ValidatedMessage msg)

toMessage :: ValidatedMessage -> Message
toMessage (ValidatedMessage m) = m

mailboxToAddress :: (AddressError -> MessageError) -> IMF.Mailbox -> Either MessageError Owl.Address
mailboxToAddress wrapErr (IMF.Mailbox displayName (IMF.AddrSpec localPart domain)) =
  case mkEmailAddress (TE.decodeLatin1 localPart <> "@" <> renderDomain domain) of
    Left addrErr -> Left (wrapErr addrErr)
    Right addr   -> Right (Owl.Address (sanitizeDisplayName displayName) addr)

renderDomain :: IMF.Domain -> Text
renderDomain (IMF.DomainDotAtom labels) =
  Text.intercalate "." (map (TE.decodeLatin1 . CI.original) (toList labels))
renderDomain (IMF.DomainLiteral lit) = "[" <> TE.decodeLatin1 lit <> "]"

expandAddress :: IMF.Address -> [IMF.Mailbox]
expandAddress (IMF.Single mbox) = [mbox]
expandAddress _                 = []  -- RFC 5322 group addresses: known v1 limitation

extractSender :: MIME.MIMEMessage -> Either MessageError Owl.Address
extractSender mimeMsg =
  case concatMap expandAddress (view (IMF.headerFrom MIME.defaultCharsets) mimeMsg) of
    []       -> Left MessageMissingSender
    mbox : _ -> mailboxToAddress MessageInvalidSender mbox

extractRecipients :: MIME.MIMEMessage -> Either MessageError [Owl.Address]
extractRecipients mimeMsg = traverse (mailboxToAddress MessageInvalidRecipient) mailboxes
  where
    mailboxes = concatMap expandAddress
      ( view (IMF.headerTo MIME.defaultCharsets) mimeMsg
          <> view (IMF.headerCC MIME.defaultCharsets) mimeMsg
      )

-- | Reply-To addresses that fail our own mailboxToAddress validation
-- are silently dropped (one at a time, not the whole header), same
-- rationale as extractReferences below: this is an interop convenience
-- header, not Message's primary identity, and a sloppy real-world
-- MUA's malformed Reply-To entry shouldn't block ingesting an
-- otherwise-valid message.
extractReplyTo :: MIME.MIMEMessage -> [Owl.Address]
extractReplyTo mimeMsg = mapMaybe toValidAddress mailboxes
  where
    mailboxes = concatMap expandAddress (view (IMF.headerReplyTo MIME.defaultCharsets) mimeMsg)
    toValidAddress mbox = either (const Nothing) Just (mailboxToAddress MessageInvalidSender mbox)

extractSubject :: MIME.MIMEMessage -> Either MessageError Subject
extractSubject mimeMsg =
  mkSubject (fromMaybe Text.empty (view (IMF.headerSubject MIME.defaultCharsets) mimeMsg))

-- | Real-world Date headers deviate from RFC 5322's own grammar
-- constantly (missing seconds, "GMT"/"UT" instead of a numeric offset,
-- stray leading/trailing whitespace, missing day-of-week) -- this list
-- is not exhaustive, but covers the specific variations that recur
-- most often in practice. Tried in order; the first format that
-- parses wins.
extractSentAt :: MIME.MIMEMessage -> Either MessageError UTCTime
extractSentAt mimeMsg =
  case preview (IMF.header "date") mimeMsg of
    Nothing       -> Left MessageMissingOrInvalidDate
    Just rawBytes ->
      let dateText = Text.unpack (Text.strip (TE.decodeLatin1 rawBytes))
      in maybe (Left MessageMissingOrInvalidDate) Right (tryDateFormats dateText)
  where
    tryDateFormats :: String -> Maybe UTCTime
    tryDateFormats s = foldr (\fmt acc -> parseTimeM True defaultTimeLocale fmt s <|> acc) Nothing dateFormats

    dateFormats :: [String]
    dateFormats =
      [ "%a, %d %b %Y %H:%M:%S %z"  -- full RFC 5322 form
      , "%d %b %Y %H:%M:%S %z"      -- missing day-of-week
      , "%a, %d %b %Y %H:%M %z"     -- missing seconds
      , "%a, %d %b %Y %H:%M:%S %Z"  -- named zone (GMT/UT/EST/...) instead of numeric offset
      , "%d %b %Y %H:%M:%S %Z"      -- missing day-of-week AND numeric zone
      ]

extractRfcId :: MIME.MIMEMessage -> Maybe ValidatedRfcId
extractRfcId mimeMsg = do
  msgId <- view IMF.headerMessageID mimeMsg
  parseRfcMessageId (TE.decodeLatin1 (IMF.renderMessageID msgId))

extractReferences :: MIME.MIMEMessage -> [ValidatedRfcId]
extractReferences mimeMsg = mapMaybe toValidated chosen
  where
    refsHeader    = view IMF.headerReferences mimeMsg
    replyToHeader = view IMF.headerInReplyTo mimeMsg
    chosen        = if null refsHeader then replyToHeader else refsHeader
    toValidated   = parseRfcMessageId . TE.decodeLatin1 . IMF.renderMessageID

extractAttachments :: MIME.MIMEMessage -> [Attachment]
extractAttachments mimeMsg = toListOf (MIME.attachments . to toOwlAttachment) mimeMsg
  where
    toOwlAttachment :: MIME.WireEntity -> Attachment
    toOwlAttachment e = Attachment
      { attachmentFilename = preview (MIME.contentDisposition . _Just . MIME.filename MIME.defaultCharsets) e
      , attachmentMimeType = maybe "application/octet-stream" TE.decodeLatin1 (preview (IMF.header "content-type") e)
      , attachmentContent  = fromMaybe ByteString.empty (preview (MIME.transferDecoded' . _Right . MIME.body) e)
      }

extractBody :: MIME.MIMEMessage -> (Maybe Text, Maybe SanitizedHtml)
extractBody mimeMsg = (plainText, sanitizeHtml <$> htmlTextRaw)
  where
    isTextPlain = MIME.matchContentType "text" (Just "plain") . view MIME.contentType
    isTextHtml  = MIME.matchContentType "text" (Just "html")  . view MIME.contentType

    plainText   = firstOf (MIME.entities . filtered isTextPlain) mimeMsg
                    >>= preview (MIME.transferDecoded' . _Right . Charset.charsetText' MIME.defaultCharsets . _Right)
    htmlTextRaw = firstOf (MIME.entities . filtered isTextHtml) mimeMsg
                    >>= preview (MIME.transferDecoded' . _Right . Charset.charsetText' MIME.defaultCharsets . _Right)
