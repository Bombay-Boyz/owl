-- | Compose, reply, send (master spec §21).
--
-- renderDraft's writer-side use of purebred-email is now verified
-- empirically rather than assumed: IMF.parseMessageID was tested
-- directly against the exact bracketed <uuid@domain> form used below,
-- and headerMessageID / headerInReplyTo / headerReferences were each
-- confirmed from purebred's own source to be proper Lens' (so `set`
-- CREATES an absent header, unlike the generic header-by-name
-- Traversal, which only modifies an existing one).
--
-- STILL NOT DONE, stated plainly:
--   * (Date is now set -- see toEnvelope's UTCTime parameter.)
--   * Attachments are not embedded in the rendered payload (the
--     multipart-construction API remains unverified). Note the
--     SMTP path DOES send them, via mime-mail -- so the stored copy
--     and the transmitted copy genuinely differ here.
--
-- The Message-ID is computed ONCE, by outgoingMessageIdText, and
-- carried on OutgoingEnvelope as envelopeMessageId so that the stored
-- copy (rendered here, via purebred) and the transmitted copy
-- (rendered by Owl.Provider.SMTP, via mime-mail) are guaranteed to
-- agree. Two independently-derived Message-IDs for the same message
-- would break thread continuity and any later "find the message I
-- sent" lookup, and nothing would catch it -- both would look
-- individually well-formed.
module Owl.Compose
  ( Draft (..)
  , newDraft
  , ReplyMode (..)
  , ReplyError (..)
  , replyTo
  , normalizeReplySubject
  , Headers (..)
  , threadHeaders
  , QuoteStyle (..)
  , quoteBody
  , OutgoingEnvelope (..)
  , ComposeError (..)
  , toEnvelope
  , rfc5322Date
  ) where

import Control.Lens (set)
import Data.Attoparsec.ByteString (parseOnly)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.CaseInsensitive as CI
import qualified Data.IMF as IMF
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.MIME as MIME
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, utc, utcToZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import qualified Data.UUID as UUID

import Owl.Domain.Address (EmailAddress, unEmailAddress)
import Owl.Domain.Attachment (Attachment)
import Owl.Domain.Body (Body (..))
import Owl.Domain.Id (AccountId, LocalId (..), MessageId (..))
import Owl.Domain.Identity (Identity (..))
import Owl.Domain.MailAddress (Address (..), sanitizeDisplayName)
import Owl.Domain.Subject (Subject, mkSubject, unSubject)
import Owl.Message.Identity (MessageIdentity (rfcId), ValidatedRfcId, unValidatedRfcId)
import Owl.Message.Types (Message)
import qualified Owl.Message.Types as MsgT

-- | §21's own diagram gives Draft exactly recipients/subject/body/
-- attachments. Three fields beyond that, each justified by a
-- DIFFERENT already-given function's actual needs, not invented
-- speculatively:
--   * draftId -- a pre-minted MessageId; becomes the sent message's
--     own identity (resolves MessageSent MessageId's own payload,
--     §24) and keys DraftState (§11).
--   * draftIdentity -- toEnvelope needs an envelopeFrom address; the
--     given 4 fields have no way to know it.
--   * draftThreadHeaders -- computed once, by replyTo/threadHeaders,
--     at the point the original Message is actually in hand; storing
--     the RESULT here (rather than the original MessageId) means
--     toEnvelope never needs to look anything up.
data Draft = Draft
  { draftId            :: !MessageId
  , draftIdentity      :: !Identity
  , draftRecipients    :: ![Address]
  , draftSubject       :: !Subject
  , draftBody          :: !Body
  , draftAttachments   :: ![Attachment]
  , draftThreadHeaders :: !(Maybe Headers)
  }
  deriving stock (Eq, Show)

-- | A fresh, non-reply compose.
newDraft :: MessageId -> Identity -> Subject -> Draft
newDraft mid ident subj = Draft
  { draftId            = mid
  , draftIdentity      = ident
  , draftRecipients    = []
  , draftSubject       = subj
  , draftBody          = Body Nothing Nothing
  , draftAttachments   = []
  , draftThreadHeaders = Nothing
  }

data ReplyMode = ReplyToSender | ReplyToAll
  deriving stock (Eq, Show)

data ReplyError = IdentityAccountMismatch AccountId AccountId  -- (identity's account, message's account)
  deriving stock (Eq, Show)

-- | MessageId is threaded in explicitly -- the same minimal, documented
-- deviation Owl.Message.Boundary.validateMessage already applies, for
-- the same reason: minting Draft's own identity means generating a
-- random UUID, an effect a pure function cannot perform itself.
replyTo :: MessageId -> ReplyMode -> Identity -> Message -> Either ReplyError Draft
replyTo newId mode ident original
  | identityAccountId ident /= MsgT.accountId original =
      Left (IdentityAccountMismatch (identityAccountId ident) (MsgT.accountId original))
  | otherwise = Right Draft
      { draftId            = newId
      , draftIdentity      = ident
      , draftRecipients    = replyRecipients
      , draftSubject       = normalizeReplySubject (MsgT.subject original)
      , draftBody          = quoteBody QuoteInline (MsgT.body original)
      , draftAttachments   = []
      , draftThreadHeaders = Just (threadHeaders original)
      }
  where
    -- Reply-To precedence: prefer the original's Reply-To addresses
    -- over its From address when present -- this is also what makes
    -- ordinary mailing-list reply behavior fall out for free (a list
    -- that sets Reply-To to itself is replied-to at the list address,
    -- with no separate special-casing needed).
    primaryTargets = if null (MsgT.replyTo original) then [MsgT.sender original] else MsgT.replyTo original

    replyRecipients = case mode of
      ReplyToSender -> primaryTargets
      ReplyToAll    -> filter ((/= identityEmailAddress ident) . addressEmail)
                         (primaryTargets ++ MsgT.recipients original)

-- | required: normalizeReplySubject (normalizeReplySubject s) ==
-- normalizeReplySubject s -- any number of leading Re:/RE:/re: prefixes
-- are stripped first, then exactly one "Re: " is added, so a second
-- application finds nothing further to strip.
normalizeReplySubject :: Subject -> Subject
normalizeReplySubject subj =
  either (const subj) id (mkSubject ("Re: " <> stripReplyPrefixes (unSubject subj)))

stripReplyPrefixes :: Text -> Text
stripReplyPrefixes t =
  let trimmed = Text.stripStart t
  in case Text.splitAt 3 trimmed of
       (prefix, rest) | Text.toCaseFold prefix == "re:" -> stripReplyPrefixes rest
       _                                                 -> trimmed

data Headers = Headers
  { headersInReplyTo  :: !(Maybe ValidatedRfcId)
  , headersReferences :: ![ValidatedRfcId]
  }
  deriving stock (Eq, Show)

threadHeaders :: Message -> Headers
threadHeaders msg = Headers
  { headersInReplyTo  = snd <$> rfcId (MsgT.identity msg)
  , headersReferences = MsgT.references msg ++ maybe [] (pure . snd) (rfcId (MsgT.identity msg))
  }

data QuoteStyle = QuoteInline | QuoteNone
  deriving stock (Eq, Show)

-- | Only the plain-text part is quoted in v1; HTML quoting (wrapping
-- in blockquote markup) is a deliberate, documented simplification --
-- most mail clients' plain-text-reply mode does exactly this, and
-- §23's TUI is a plain-text renderer anyway (§7: no speculative
-- abstraction ahead of a real need).
quoteBody :: QuoteStyle -> Body -> Body
quoteBody QuoteNone _ = Body Nothing Nothing
quoteBody QuoteInline original = Body
  { bodyPlainText = quotePlain <$> bodyPlainText original
  , bodyHtml      = Nothing
  }
  where
    quotePlain = Text.unlines . map ("> " <>) . Text.lines

-- | envelopePayload is the fully-rendered RFC5322/MIME wire bytes
-- (via purebred-email) -- kept for storage/display purposes (an exact
-- Sent-folder copy, a "view source" feature), but NOT what
-- Owl.Provider.SMTP actually transmits: HaskellNet's own sendMail
-- requires a structured Network.Mail.Mime.Mail value, not raw bytes,
-- so the provider adapter reconstructs one from this envelope's own
-- structured fields via mime-mail -- a second mature MIME library, not
-- a hand-rolled one, deriving from the exact same Draft data as
-- envelopePayload, so the two should never meaningfully diverge in
-- content, only in lower-level formatting choices.
data OutgoingEnvelope = OutgoingEnvelope
  { envelopeSender        :: !Address
  , envelopeRecipients    :: !(NonEmpty Address)
  , envelopeSubjectText   :: !Subject
  , envelopeBodyPlain     :: !(Maybe Text)
  , envelopeAttachments   :: ![Attachment]
  , envelopeThreadHeaders :: !(Maybe Headers)
    -- ^ Fixing a real gap: this was computed by replyTo/threadHeaders
    -- and stored on Draft, but never actually reached the sent
    -- message -- a reply was going out threading-blind. Carried here
    -- so Owl.Provider.SMTP can set In-Reply-To/References on what is
    -- actually transmitted.
  , envelopeDate          :: !UTCTime
    -- ^ The instant the message was composed. Carried as an INSTANT,
    -- not pre-formatted text, and deliberately unlike
    -- envelopeMessageId: a Message-ID is an identifier where any
    -- divergence between the two renderers is a real bug, whereas two
    -- valid RFC 5322 renderings of the same instant are equivalent.
    -- So each renderer formats this itself.
  , envelopeMessageId     :: !Text
    -- ^ This message's Message-ID, in its full <...> form. Shared
    -- deliberately: see this module's header note on why both
    -- renderers must use the same value rather than each deriving
    -- their own.
  , envelopePayload       :: !ByteString
  }
  deriving stock (Eq, Show)

data ComposeError = NoRecipients
  deriving stock (Eq, Show)

-- | The one place recipients go from "maybe none yet" to "guaranteed
-- at least one" -- a Draft with no recipients is a real, valid,
-- incomplete state (§12's rule); an OutgoingEnvelope with none is not,
-- and this is where that's enforced.
-- | The UTCTime is supplied by the caller rather than read here: "now"
-- is an effect, and this function is pure. Exactly the pattern already
-- used for MessageId in Owl.Message.Boundary.validateMessage and in
-- replyTo above.
toEnvelope :: UTCTime -> Draft -> Either ComposeError OutgoingEnvelope
toEnvelope now draft = case NE.nonEmpty (draftRecipients draft) of
  Nothing            -> Left NoRecipients
  Just recipientsNE -> Right OutgoingEnvelope
    { envelopeSender        = Address (identityDisplayName (draftIdentity draft)) (identityEmailAddress (draftIdentity draft))
    , envelopeRecipients    = recipientsNE
    , envelopeSubjectText   = draftSubject draft
    , envelopeBodyPlain     = bodyPlainText (draftBody draft)
    , envelopeAttachments   = draftAttachments draft
    , envelopeThreadHeaders = draftThreadHeaders draft
    , envelopeDate          = now
    , envelopeMessageId     = outgoingMessageIdText draft
    , envelopePayload       = renderDraft now draft
    }

-- | Renders the outgoing wire bytes. Sets Message-ID and, for a reply,
-- In-Reply-To/References -- all three of which were previously absent,
-- found by dumping the actual rendered bytes rather than by reading
-- the code.
--
-- The missing Message-ID was the serious one: we already set
-- In-Reply-To on replies, i.e. we asked recipients to thread our mail
-- into their conversations while giving them nothing to thread a reply
-- back TO. Every reply to Owl-sent mail would have started an orphan
-- thread.
renderDraft :: UTCTime -> Draft -> ByteString
renderDraft now draft = LBS.toStrict (MIME.renderMessage populated)
  where
    base = MIME.createTextPlainMessage (fromMaybe Text.empty (bodyPlainText (draftBody draft)))
    fromMailbox = addressToMailbox (Address (identityDisplayName (draftIdentity draft)) (identityEmailAddress (draftIdentity draft)))
    toMailboxes = map addressToMailbox (draftRecipients draft)
    populated =
      applyThreadHeaders (draftThreadHeaders draft)
        -- UTC always, never the local zone: a +0530 offset narrows the
        -- sender's location to a ~1,500km band (docs/header-privacy.md
        -- R3). purebred renders this via its own renderRFC5322Date.
        . set IMF.headerDate (Just (utcToZonedTime utc now))
        . set IMF.headerMessageID (outgoingMessageID draft)
        . set (IMF.headerFrom MIME.defaultCharsets) [IMF.Single fromMailbox]
        . set (IMF.headerTo MIME.defaultCharsets) (map IMF.Single toMailboxes)
        . set (IMF.headerSubject MIME.defaultCharsets) (Just (unSubject (draftSubject draft)))
        $ base

-- | This message's own Message-ID, as <uuid@sender-domain>.
--
-- Satisfies two things at once:
--
--   * Uniqueness, from the UUID that MessageId already carries -- no
--     timestamp, no PID, no counter.
--   * Privacy (docs/header-privacy.md R1): deliberately NOT the
--     conventional <timestamp.pid.hostname@domain> form, which leaks
--     the sending machine's hostname and often its username. The
--     right-hand side is the sender's own mail domain, already visible
--     in From, so this reveals nothing new.
--
-- Nothing only if purebred's own parser rejects the constructed ID,
-- which for a UUID plus an already-validated domain should be
-- unreachable -- reported as absent rather than crashed, per §30.
outgoingMessageID :: Draft -> Maybe IMF.MessageID
outgoingMessageID = parseMessageIdText . outgoingMessageIdText

-- | The single source of truth for this message's Message-ID text.
-- Both renderers go through here -- outgoingMessageID for the stored
-- copy, envelopeMessageId for the transmitted one -- so they cannot
-- disagree.
outgoingMessageIdText :: Draft -> Text
outgoingMessageIdText draft = "<" <> UUID.toText uuid <> "@" <> senderDomain <> ">"
  where
    MessageId (LocalId uuid) = draftId draft
    senderDomain =
      Text.drop 1 (Text.dropWhile (/= '@')
        (unEmailAddress (identityEmailAddress (draftIdentity draft))))

-- | Sets In-Reply-To and References for a reply. Both are proper
-- Lens' in purebred (confirmed from its source), so `set` creates the
-- headers when absent.
--
-- A ValidatedRfcId that purebred's parser rejects is dropped rather
-- than failing the whole render: our own parseRfcMessageId already
-- accepted it, so disagreement between the two parsers must not cost
-- the user their outgoing message. The cost is a silently weaker
-- thread link, which matches how Owl.Message.Boundary already treats
-- unparseable inbound references.
applyThreadHeaders :: Maybe Headers -> MIME.MIMEMessage -> MIME.MIMEMessage
applyThreadHeaders Nothing     msg = msg
applyThreadHeaders (Just hdrs) msg =
  set IMF.headerReferences referenceIds
    . maybe id (\rid -> set IMF.headerInReplyTo [rid]) inReplyToId
    $ msg
  where
    inReplyToId  = headersInReplyTo hdrs >>= toMessageID
    referenceIds = mapMaybe toMessageID (headersReferences hdrs)
    toMessageID  = parseMessageIdText . unValidatedRfcId

-- | One place that turns our own <...> text into purebred's MessageID,
-- shared by the Message-ID and thread-header paths.
parseMessageIdText :: Text -> Maybe IMF.MessageID
parseMessageIdText t =
  either (const Nothing) Just (parseOnly IMF.parseMessageID (TE.encodeUtf8 t))

addressToMailbox :: Address -> IMF.Mailbox
addressToMailbox addr = IMF.Mailbox (sanitizeDisplayName (addressDisplayName addr)) (emailToAddrSpec (addressEmail addr))

-- | Provably unreachable fallback for an already-validated EmailAddress
-- (mkEmailAddress guarantees a non-empty domain with at least one
-- label) -- handled defensively rather than partially, per §30.
emailToAddrSpec :: EmailAddress -> IMF.AddrSpec
emailToAddrSpec email =
  let (localPart, domainPart) = Text.breakOn "@" (unEmailAddress email)
      domainText              = Text.drop 1 domainPart
      labels                  = fromMaybe ("invalid" :| []) (NE.nonEmpty (Text.splitOn "." domainText))
  in IMF.AddrSpec (TE.encodeUtf8 localPart) (IMF.DomainDotAtom (fmap (CI.mk . TE.encodeUtf8) labels))


-- | RFC 5322 date, in UTC. Deliberately the same pattern that
-- Owl.Message.Boundary.extractSentAt tries FIRST, so Owl can always
-- parse back a date it wrote itself -- a property worth having and
-- worth testing.
--
-- Used by the mime-mail path (Owl.Provider.SMTP); the purebred path
-- uses IMF.headerDate, which formats via purebred's own
-- renderRFC5322Date. The two strings may differ in incidental
-- whitespace while denoting the same instant, which is fine -- see
-- envelopeDate's note on why this differs from Message-ID.
rfc5322Date :: UTCTime -> Text
rfc5322Date =
  Text.pack . formatTime defaultTimeLocale "%a, %d %b %Y %H:%M:%S %z" . utcToZonedTime utc
