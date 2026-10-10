{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-unused-matches -Wno-unused-top-binds -Wno-missing-methods #-}

module Owl where

import Data.Text (Text)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Foldable (for_, toList)
import Data.Time (UTCTime, Day)
import Data.Word (Word16, Word64, Word)
import Data.UUID (UUID)
import Data.Sequence (Seq)
import Data.List (foldl')
import Control.Concurrent.STM
import Control.Concurrent.STM.TMVar
import Control.Concurrent.Async (Async)

-- =====================================================================
-- Stub types: referenced throughout the spec, deliberately left
-- abstract there (per §10's own "left for implementation" rule) or
-- implied by usage without a top-level declaration. Given no
-- constructors here since this file only checks structural/type
-- consistency, not runtime behavior.
-- =====================================================================

data ConfigSource
data ConfigError
data RawConfig
data Config
data KeyringError
data OAuth2Endpoints
data AddressError
data MessageError
data ParseError
data CharsetError
data RawMessage
data DecodedMessage
data ValidatedMessage
data ThreadBuildState
data ThreadError
data Field
data Phrase
data Flag
data Body
data QuoteStyle
data Headers
data ReplyMode
data ReplyError
data ComposeError
data SearchLexError
data SearchParseError
data BM25Parameters
data QueryTerms
data RecipientQuery
data AddressBook
data RecipientCandidate
data NormalizedText
data MailboxMeta
data StoreQueryError
data StorePlan
data StoreError
data SyncConflict
data SyncCursor
data RemoteDelta
data ProviderSession
data UID
data UIDValidity
data Token
data UiError
data UserInput
data InboxView
data Doc
data MessageState
data ThreadState
data ContactState
data DraftState
data SyncOutcome
data SyncFailure
data Attempt
data Duration
data SearchIndexDelta
data ThreadIndexDelta
data UIState
data PositiveInt

newtype MessageCount = MessageCount Int
  deriving newtype (Num, Eq, Ord)

-- RemoteObservation is used with (==) in classify (§19) — must derive Eq.
-- Given one real constructor (rather than zero) so GHC's pattern-match
-- exhaustiveness checker exercises classify/toReconciliationInput
-- properly instead of treating every branch as unreachable.
data RemoteObservation = RemoteObservation
  deriving (Eq)

-- Note: Account/Identity/Person/Address/Contact/Thread/Mailbox/Label/
-- Attachment/Draft are NOT stubbed here — they come from the extracted
-- §10 block itself, appended below. Stubbing them here too would be a
-- duplicate declaration I introduced, not one from the spec.

-- Implied helper functions used inside applyM's real body (§27) but
-- never given their own top-level signature elsewhere in the document —
-- typed here only as needed to make applyM's usage typecheck.
deltaFor :: Event -> IndexDelta
deltaFor = undefined

applySearchDelta :: InvertedIndex -> SearchIndexDelta -> InvertedIndex
applySearchDelta = undefined

applyDocStatsDelta :: DocumentStatistics -> SearchIndexDelta -> DocumentStatistics
applyDocStatsDelta = undefined

applyThreadDelta :: Map ThreadId ThreadForest -> ThreadIndexDelta -> Map ThreadId ThreadForest
applyThreadDelta = undefined

-- obsRef :: extracts the RemoteRef from a RemoteObservation — used in
-- classify (§19) but likewise never separately declared.
obsRef :: RemoteObservation -> RemoteRef
obsRef = undefined

loadConfig     :: ConfigSource -> IO (Either ConfigError Config)
validateConfig :: RawConfig -> Either ConfigError Config

newtype Domain = Domain Text

data ServerEndpoint = ServerEndpoint
  { endpointHost     :: !Text
  , endpointPort     :: !Word16
  , endpointSecurity :: !TransportSecurity
  }

data TransportSecurity = TLSImplicit | STARTTLS

data ProviderConfig = ProviderConfig
  { imapEndpoint :: !ServerEndpoint
  , smtpEndpoint :: !ServerEndpoint
  , authMethod   :: !AuthMechanism
  }

data AuthMechanism = OAuth2 !OAuth2Endpoints | PasswordAuth

data DiscoveryError = DomainParseFailed Text | DnsLookupFailed Text | NoEndpointsDiscovered

discoverProvider :: EmailAddress -> IO (Either DiscoveryError ProviderConfig)

data KeyringHandle m = KeyringHandle
  { storeSecret  :: AccountId -> ByteString -> m (Either KeyringError ())
  , loadSecret   :: AccountId -> m (Either KeyringError ByteString)
  , deleteSecret :: AccountId -> m (Either KeyringError ())
  }

data WizardError
  = WizardDiscoveryFailed DiscoveryError
  | WizardAuthFailed AuthError
  | WizardConnectionFailed ProviderError   -- §20
  | WizardCancelled

data WizardStep
  = PromptEmail | Discovering EmailAddress | Authenticate ProviderConfig
  | TestingConnection ProviderConfig | Complete | Failed WizardError

data WizardEvent
  = EmailEntered EmailAddress | DiscoveryDone (Either DiscoveryError ProviderConfig)
  | AuthDone (Either AuthError ()) | ConnectionTested (Either ProviderError ()) | Cancelled

stepWizard :: WizardStep -> WizardEvent -> WizardStep

newtype AccountId    = AccountId Text
  deriving (Eq, Ord)
newtype LocalId      = LocalId UUID          -- Owl's own identity; see §13
  deriving (Eq, Ord)
newtype MessageId    = MessageId LocalId     -- never a raw Text, never an IMAP UID
  deriving (Eq, Ord)
newtype ThreadId     = ThreadId Text          -- Owl-issued; unique across accounts, see below
  deriving (Eq, Ord)
newtype PersonId     = PersonId Text
  deriving (Eq, Ord)
newtype AddressId    = AddressId Text
  deriving (Eq, Ord)
newtype MailboxId    = MailboxId Text         -- Owl-issued; unique across accounts, see below
  deriving (Eq, Ord)
newtype LabelId      = LabelId Text
  deriving (Eq, Ord)
newtype EmailAddress = EmailAddress Text   -- display/canonical form; casing preserved
  deriving (Eq, Ord)
newtype Subject      = Subject Text
  deriving (Eq, Ord)

mkEmailAddress :: Text -> Either AddressError EmailAddress
mkSubject      :: Text -> Either MessageError Subject

-- Every identity newtype above derives (Eq, Ord): each is used as a Map
-- or Set key somewhere in this document (MessageId, MailboxId, ThreadId,
-- AccountId especially — §15, §17, §19, §27), and Data.Map/Data.Set
-- require Ord on the key type. Stated once, here, rather than repeated
-- per call site.

-- | Comparison key for dedup, indexing, and matching — never used for
-- display or the SMTP envelope. Per RFC 5321 the local part is
-- technically case-sensitive, but no major provider treats it that way
-- in practice, while the domain part is explicitly case-insensitive.
-- Owl folds the domain and normalizes the local part for matching only;
-- `EmailAddress` itself keeps the original casing for everything
-- user-facing. Used at exactly three call sites: the `Address` search
-- index (§15), `ContactIndex` (§16), and dedup of colliding observations
-- in `RemoteSnapshot` (§19) — nowhere else needs it.
newtype NormalizedAddress = NormalizedAddress Text
  deriving (Eq, Ord)

normalizeAddress :: EmailAddress -> NormalizedAddress

data Account
data Identity
data Person
data Address
data Contact
-- Message: fully defined in §12, not left abstract here
data Thread
data Mailbox
data Label
data Attachment
data Draft

data Application = Application
  { messages  :: !MessageState
  , threads   :: !ThreadState
  , contacts  :: !ContactState
  , mailboxes :: !MailboxState
  , drafts    :: !DraftState
  , sync      :: !(Map AccountId SyncState)  -- one account's sync status can't stand in for another's, see §19
  }

-- | The canonical mailbox-membership relation. Multi-valued deliberately:
-- a message can be In("Inbox") and In("Work") simultaneously.
newtype MailMembership = MailMembership (Map MessageId (Set MailboxId))

data MailboxState = MailboxState
  { membership     :: !MailMembership
  , mailboxCatalog :: !(Map MailboxId MailboxMeta)  -- names, kind, hierarchy
  }

parseMessage    :: ByteString -> Either ParseError RawMessage
decodeCharset   :: RawMessage -> Either CharsetError DecodedMessage
  -- ^ Header/body text decoded per its declared or detected charset (RFC 2047
  -- encoded words included) before any domain code sees it. A missing or
  -- invalid declared charset falls back to a fixed, documented default
  -- (never a silent per-message guess), and the fallback path is itself
  -- deterministic. Round-tripping this back to wire form for storage or
  -- resend (§21) must preserve meaning; where it can't, that lossiness is
  -- a named `CharsetError` case, not a silent substitution.
validateMessage :: DecodedMessage -> Either MessageError ValidatedMessage
toMessage       :: ValidatedMessage -> Message

data Message = Message
  { identity    :: !MessageIdentity   -- see §13; carries the MessageId
  , accountId   :: !AccountId          -- owning account; see §10's multi-account identity note
  , threadId    :: !ThreadId
  , sender      :: !Address
  , recipients  :: ![Address]          -- may legitimately be empty; see below
  , subject     :: !Subject
  , sentAt      :: !UTCTime
  , body        :: !Body
  , attachments :: ![Attachment]
  , flags       :: !(Set Flag)
  }

-- | An RFC 5322 Message-ID that has passed validation. Only constructible
-- via parseRfcMessageId — a value of this type is a guarantee, not a hope.
newtype ValidatedRfcId = ValidatedRfcId Text
  deriving (Eq, Ord, Show)

parseRfcMessageId :: Text -> Maybe ValidatedRfcId

data MessageIdentity = MessageIdentity
  { messageId :: !MessageId                          -- Owl's own identity (§10); the primary key
  , rfcId     :: !(Maybe (AccountId, ValidatedRfcId)) -- secondary heuristic index, scoped per account
  }

-- | A remote identifier is an observation about a message, valid only
-- alongside the UIDVALIDITY epoch it was observed under.
data RemoteRef = ImapRef !MailboxId !UIDValidity !UID

data MessageNode = MessageNode
  { nodeMessage  :: Maybe Message   -- Nothing for a referenced-but-absent message
  , nodeChildren :: [MessageNode]
  }

newtype ThreadForest = ThreadForest (NonEmpty MessageNode)

-- | Raw referenced ids as parsed straight from Message-ID/In-Reply-To/
-- References headers — these are RFC ids, not yet Owl's local MessageId.
messageReferences :: Message -> [ValidatedRfcId]

-- | Resolves a raw header reference to a locally-known message, scoped to
-- the account being threaded — this is exactly why §13 scopes rfcId by
-- AccountId. Nothing means "referenced but not present locally," which is
-- the ordinary JWZ dummy-node case, not an error.
resolveReference :: AccountId -> ValidatedRfcId -> ThreadBuildState -> Maybe MessageId

threadMessages :: AccountId -> NonEmpty Message -> Either ThreadError ThreadForest

-- | Before linking a container as a child of a candidate parent, walk the
-- parent's existing ancestor chain. True means linking would create a cycle.
wouldCreateCycle :: ThreadBuildState -> MessageId -> MessageId -> Bool

-- | Shared boolean predicate core: the vocabulary of "what does a message
-- match," used identically by search (this section) and rule matching
-- (§22). One type, one evaluator, one property-test suite — not two
-- independently-drifting ADTs.
data Predicate
    = From EmailAddress
    | To EmailAddress
    | SubjectContains Text
    | Body Phrase
    | HasAttachment
    | IsUnread
    | InMailbox MailboxId
    | InThread ThreadId
    | After Day
    | Before Day
    | And (NonEmpty Predicate)
    | Or  (NonEmpty Predicate)
    | Not Predicate

-- | A search query is exactly a Predicate. Kept as a distinct name at call
-- sites for readability; there is no separate constructor set to maintain.
type Query = Predicate

data QueryToken = TokField Field | TokText Text | TokPhrase Text
                | TokAnd | TokOr | TokNot | TokLParen | TokRParen

lexQuery   :: Text -> Either SearchLexError [QueryToken]
parseQuery :: Text -> Either SearchParseError Query

-- | Live, incomplete input (search-as-you-type). An unterminated trailing
-- token is treated as a prefix match against the last complete field
-- rather than a syntax error. Used only by the live search box; every
-- submitted query, saved search, and rule (§22) still goes through the
-- strict parseQuery above.
parseQueryLive :: Text -> Query

matches :: Message -> Predicate -> Bool

newtype Term = Term Text
  deriving (Eq, Ord)  -- used as the key of InvertedIndex's Map, below

-- | One occurrence record within a term's postings: which message, and
-- how many times the term appears in it — BM25's f(t,D) needs this, and
-- a bare [MessageId] posting list can't carry it.
data Posting = Posting
  { postingMessage :: !MessageId
  , postingTf      :: !Word
  }

newtype PostingList = PostingList [Posting]   -- sorted by MessageId

newtype InvertedIndex = InvertedIndex (Map Term PostingList)

-- | Per-document length and the corpus average, maintained incrementally
-- as an IndexDelta target (§17) alongside the postings themselves — BM25
-- needs both, and neither is derivable from PostingList alone.
data DocumentStatistics = DocumentStatistics
  { docLength    :: !(Map MessageId Word)
  , avgDocLength :: !Double
  }

bm25 :: BM25Parameters -> DocumentStatistics -> QueryTerms -> MessageId -> Double

data MatchKind = ExactAddress | ExactName | AliasMatch | PrefixMatch | ContainsMatch

data CandidateScore = CandidateScore
  { matchRank     :: Int
  , recentRank    :: Int
  , frequencyRank :: Int
  , stableId      :: PersonId   -- tie-breaker: guarantees determinism
  }
  deriving (Eq, Ord)

scoreCandidate    :: RecipientQuery -> Contact -> CandidateScore
resolveRecipients :: RecipientQuery -> AddressBook -> [RecipientCandidate]   -- may be empty: "no match" is a real result

type ContactIndex = Map NormalizedText (Set PersonId)

data IndexDelta = IndexDelta
  { searchDelta :: !(Maybe SearchIndexDelta)  -- Nothing: this event has no postings/DocumentStatistics change
  , threadDelta :: !(Maybe ThreadIndexDelta)  -- Nothing: this event doesn't change thread structure
  }

data StoreQuery = GetMessage MessageId | Search Query | ListMailbox MailboxId

planQuery :: StoreQuery -> Either StoreQueryError StorePlan

data StoreHandle m = StoreHandle
  { loadMessage    :: MessageId -> m (Either StoreError Message)
  , saveMessage    :: Message   -> m (Either StoreError ())
  , searchMessages :: Query     -> m (Either StoreError (Set MessageId))
  }

-- | Keyed on the identity types already defined in §13, not a generic
-- LocalId/RemoteId pair — a decision is always about a specific message
-- (MessageId) or a specific mailbox-level change.
data SyncDecision
    = Pull RemoteRef | Push MessageId
    | DeleteLocal MessageId | DeleteRemote RemoteRef
    | MoveMailbox MailboxId
    | NoChange | Conflict SyncConflict

newtype SyncPlan = SyncPlan (NonEmpty SyncDecision)
  deriving newtype (Semigroup)

reconcile :: LocalSnapshot -> RemoteSnapshot -> Either SyncError SyncPlan
reconcile local remote = do
  decisions <- traverse decide (toList (Map.keysSet local <> Map.keysSet remote))
  case nonEmpty decisions of
    Nothing -> pure (SyncPlan (NoChange :| []))  -- both snapshots empty: nothing to reconcile
    Just ds -> pure (SyncPlan ds)
  where
    decide mid = case reconcileOne mid (Map.lookup mid local) (Map.lookup mid remote) of
      Just d  -> Right d
      Nothing -> Left (ImpossibleReconciliationKey mid)  -- see §28; provably dead given the fold above

data LocalRecord
  = KnownRemote            !RemoteObservation  -- synced before; no local edit since
  | PendingEdit             !Event             -- originated locally; never observed remotely
  | KnownRemoteWithPending  !RemoteObservation !Event  -- synced before, then edited locally, not yet pushed

type LocalSnapshot  = Map MessageId LocalRecord
type RemoteSnapshot = Map MessageId RemoteObservation

-- | Everything relevant to reconciling one message, merged from both
-- snapshots into a single closed type. There is deliberately no
-- constructor for "no LocalRecord and no RemoteObservation" — `reconcile`
-- only ever looks a key up here after drawing it from the union of both
-- snapshots' keys, so at least one side is always present.
data ReconciliationInput
  = RemoteArrival          !RemoteObservation             -- no local history; remote has it
  | LocalOnlyEdit           !Event                        -- originated locally; remote doesn't have it yet
  | UnbaselinedConflict     !Event !RemoteObservation      -- pending edit, no baseline, remote shows something
  | RemoteDeleted           !RemoteObservation             -- known baseline, no edit, remote now gone
  | Baseline                !RemoteObservation !RemoteObservation  -- known baseline, no edit, remote present
  | EditUnderDeletion       !RemoteObservation !Event      -- known baseline, pending edit, remote now gone
  | EditAgainstBaseline     !RemoteObservation !RemoteObservation !Event -- known baseline, edit, remote present

-- | Total: eight input combinations, seven of them meaningful. The
-- eighth — no LocalRecord, no RemoteObservation — can't arise from
-- `reconcile`'s fold, so this returns Maybe rather than smuggling a
-- fake decision in for an input that should never reach it.
toReconciliationInput :: Maybe LocalRecord -> Maybe RemoteObservation -> Maybe ReconciliationInput
toReconciliationInput Nothing                              Nothing    = Nothing
toReconciliationInput Nothing                              (Just cur) = Just (RemoteArrival cur)
toReconciliationInput (Just (PendingEdit e))                Nothing    = Just (LocalOnlyEdit e)
toReconciliationInput (Just (PendingEdit e))                (Just cur) = Just (UnbaselinedConflict e cur)
toReconciliationInput (Just (KnownRemote lkr))              Nothing    = Just (RemoteDeleted lkr)
toReconciliationInput (Just (KnownRemote lkr))              (Just cur) = Just (Baseline lkr cur)
toReconciliationInput (Just (KnownRemoteWithPending lkr e)) Nothing    = Just (EditUnderDeletion lkr e)
toReconciliationInput (Just (KnownRemoteWithPending lkr e)) (Just cur) = Just (EditAgainstBaseline lkr cur e)

-- | Deliberately plain pattern matching, not a CRDT join-semilattice:
-- Owl has exactly one authority (the server) it is always eventually
-- reconciling against, so an explicit precedence rule is sufficient and
-- far cheaper than generic convergence machinery. `Push` and
-- `DeleteLocal` need the key itself (`SyncDecision`'s constructors carry
-- a `MessageId`, not an `Event`), which is why this takes `mid` rather
-- than deriving it from the input.
classify :: MessageId -> ReconciliationInput -> SyncDecision
classify mid = \case
  RemoteArrival cur                -> Pull (obsRef cur)
  LocalOnlyEdit _                  -> Push mid
  UnbaselinedConflict e cur        -> Conflict (mkConflict mid e (Just cur))
  RemoteDeleted _                  -> DeleteLocal mid
  Baseline lkr cur
    | lkr == cur                   -> NoChange
    | otherwise                    -> Pull (obsRef cur)
  EditUnderDeletion _ e            -> Conflict (mkConflict mid e Nothing)
  EditAgainstBaseline lkr cur e
    | lkr == cur                   -> Push mid
    | otherwise                    -> Conflict (mkConflict mid e (Just cur))

-- | Per-message resolution. `Nothing` only for the key combination
-- `toReconciliationInput` also returns `Nothing` for — provably
-- unreachable given how `reconcile` builds its key set (below) — so
-- `reconcile` treats it as the invariant violation it would actually be
-- if it ever fired, rather than silently dropping the key.
reconcileOne :: MessageId -> Maybe LocalRecord -> Maybe RemoteObservation -> Maybe SyncDecision
reconcileOne mid localRecord currentRemote =
  classify mid <$> toReconciliationInput localRecord currentRemote

mkConflict :: MessageId -> Event -> Maybe RemoteObservation -> SyncConflict

execute :: SyncPlan -> IO SyncOutcome

data SyncState = NotSynced | Syncing | Synchronized | NeedsRetry SyncFailure

data SyncEvent = SyncStarted | RemoteChanged | LocalChanged
               | SyncCompleted | SyncFailed SyncFailure

-- | Operates on one account's current state; the caller (which already
-- knows which account produced the event, per §27's per-account workers)
-- applies the result at that AccountId's key in Application.sync (§11) —
-- transition itself stays a plain one-account state machine, not a map.
transition :: SyncState -> SyncEvent -> Either SyncError SyncState

data RetryPolicy = RetryPolicy { maxAttempts :: PositiveInt, backoff :: Attempt -> Duration }
nextAttempt :: RetryPolicy -> Attempt -> Maybe Duration

-- | A connection lost after the SMTP payload was handed off is not the
-- same as a clean rejection — the message may have been accepted. That
-- ambiguity is represented explicitly, the same way §19 represents sync
-- ambiguity, rather than collapsed into a plain failure that would
-- invite a blind (possibly duplicate) retry.
data SendOutcome = Sent | SendOutcomeUnknown

sendMessage :: ProviderSession -> OutgoingEnvelope -> IO (Either ProviderError SendOutcome)

replyTo :: ReplyMode -> Identity -> Message -> Either ReplyError Draft

normalizeReplySubject :: Subject -> Subject
-- required: normalizeReplySubject (normalizeReplySubject s) == normalizeReplySubject s

threadHeaders :: Message -> Headers
quoteBody     :: QuoteStyle -> Body -> Body

data OutgoingEnvelope = OutgoingEnvelope
  { envelopeFrom :: !EmailAddress
  , envelopeTo   :: !(NonEmpty EmailAddress)  -- meaningless with zero RCPT TO; guaranteed here, nowhere else
  , envelopePayload :: !ByteString
  }

-- | The one place recipients go from "maybe none yet" to "guaranteed at
-- least one" — a Draft with no recipients is a real, valid, incomplete
-- state (§12's rule); an OutgoingEnvelope with none is not, and this is
-- where that's enforced.
toEnvelope :: Draft -> Either ComposeError OutgoingEnvelope

-- Predicate is defined once, in §15, and reused here unchanged — see the
-- note there on why search and rules share a single evaluator.

data Action = Archive | MarkRead | MarkUnread | Delete | Label LabelId | Move MailboxId

-- | Field is `ruleActions`, not `then` — `then` is a reserved Haskell
-- keyword and cannot be a field name.
data Rule = Rule
  { ruleWhen    :: !Predicate
  , ruleActions :: !(NonEmpty Action)
  }

evaluateRules :: [Rule] -> Message -> [Action]

-- | Constructors here are named distinctly from Action (§22) and
-- StoreQuery (§18) even where the underlying verb is the same — a
-- keyboard command, a rule action, and a store query are different
-- things that happen to share English verbs (archive, delete, search),
-- and Haskell constructors share one flat namespace per module, so the
-- three types can't reuse Archive/Delete/MarkRead/MarkUnread/Search
-- unqualified. Same fix as Token/QueryToken in §15.
data Command
    = OpenThread ThreadId | SearchCommand Query | Reply ThreadId | Forward MessageId
    | Compose | ArchiveThread ThreadId | DeleteMessage MessageId
    | MarkMessageRead MessageId | MarkMessageUnread MessageId | Quit

data Screen = InboxScreen | ThreadScreen ThreadId | SearchScreen
            | ComposeScreen | ContactScreen | HelpScreen

transitionScreen :: Screen -> Command -> Either UiError Screen

view    :: Application -> UIState -> Screen
command :: UserInput -> Application -> UIState -> Either CommandError (NonEmpty Event)

renderInbox :: InboxView -> Doc   -- narrow view models, not deep domain structures

commandsFor :: Screen -> Set Command

data Event
    = MessageReceived Message
    | MessageRead MessageId | MessageUnread MessageId
    | MessageArchived MessageId | MessageUnarchived MessageId
    | MessageDeleted MessageId | MessageRestored MessageId
    | MessageMoved MessageId MailboxId MailboxId   -- from, to — needed to invert, see Undo below
    | MessageLabeled MessageId MailboxId           -- adds one MailMembership entry (§11); others untouched
    | MessageUnlabeled MessageId MailboxId         -- removes exactly one MailMembership entry
    | DraftCreated Draft | DraftChanged Draft | MessageSent MessageId
    | ContactChanged Contact

apply :: Event -> Application -> Either DomainError Application

markRead :: MessageId -> Application -> Application

newtype UndoStack = UndoStack (Seq Event)   -- capped at ~10 entries

invertEvent :: Event -> Maybe Event
invertEvent (MessageRead mid)          = Just (MessageUnread mid)
invertEvent (MessageUnread mid)        = Just (MessageRead mid)
invertEvent (MessageArchived mid)      = Just (MessageUnarchived mid)
invertEvent (MessageUnarchived mid)    = Just (MessageArchived mid)
invertEvent (MessageDeleted mid)       = Just (MessageRestored mid)
invertEvent (MessageRestored mid)      = Just (MessageDeleted mid)
invertEvent (MessageMoved mid from to) = Just (MessageMoved mid to from)
invertEvent (MessageLabeled mid mbox)  = Just (MessageUnlabeled mid mbox)
invertEvent (MessageUnlabeled mid mbox)= Just (MessageLabeled mid mbox)
invertEvent _                          = Nothing   -- MessageSent, MessageReceived, drafts: no inverse

data RuntimeState = RuntimeState
  { rsApplicationVar :: !(TVar Application)
  , rsSearchIndexVar :: !(TVar InvertedIndex)        -- §15
  , rsDocStatsVar    :: !(TVar DocumentStatistics)   -- §15
  , rsThreadIndexVar :: !(TVar (Map ThreadId ThreadForest))  -- §14
  , rsGeneration     :: !(TVar Word64)               -- see awaitChange, below
  }

applyM :: RuntimeState -> Event -> STM (Either DomainError ())
applyM rt event = do
  app <- readTVar (rsApplicationVar rt)
  case apply event app of
    Left err   -> pure (Left err)
    Right app' -> do
      writeTVar (rsApplicationVar rt) app'
      let delta = deltaFor event   -- §17's IndexDelta
      -- Only a TVar a given delta actually changes is written — a
      -- MessageRead's IndexDelta has searchDelta = threadDelta = Nothing,
      -- so it writes rsApplicationVar and rsGeneration only, and never
      -- conflicts with a concurrent reader of the search or thread index.
      for_ (searchDelta delta) $ \sd -> do
        modifyTVar' (rsSearchIndexVar rt) (`applySearchDelta` sd)
        modifyTVar' (rsDocStatsVar rt)    (`applyDocStatsDelta` sd)
      for_ (threadDelta delta) $ \td ->
        modifyTVar' (rsThreadIndexVar rt) (`applyThreadDelta` td)
      modifyTVar' (rsGeneration rt) (+1)
      pure (Right ())

-- | A consistent cross-substate read, for the callers that genuinely need
-- more than one field together (e.g. `view`, building an InboxView from
-- both MailMembership and the Date index). Reading fewer TVars than this
-- — e.g. a thread-open that only needs rsApplicationVar and
-- rsThreadIndexVar — is preferred wherever the caller can, precisely
-- because every extra TVar read here is one more thing a concurrent
-- writer can conflict with.
readRuntimeSnapshot :: RuntimeState -> STM (Application, InvertedIndex, Map ThreadId ThreadForest)
readRuntimeSnapshot rt = (,,)
  <$> readTVar (rsApplicationVar rt)
  <*> readTVar (rsSearchIndexVar rt)
  <*> readTVar (rsThreadIndexVar rt)

awaitChange :: RuntimeState -> Word64 -> STM Word64
awaitChange rt lastSeenGeneration = do
  current <- readTVar (rsGeneration rt)
  if current == lastSeenGeneration then retry else pure current

newtype RefreshGuard = RefreshGuard (TMVar (Maybe (Async (Either AuthError Token))))

refreshToken :: RefreshGuard -> Account -> IO (Either AuthError Token)

-- | One guard per account, not one process-wide guard — a stuck refresh
-- on one account must never block a healthy one.
newtype RefreshGuards = RefreshGuards (TVar (Map AccountId RefreshGuard))

-- | A fixed-size worker pool services IMAP IDLE/poll and SMTP send
-- across *all* accounts, rather than one thread per account; the pool
-- size is a config default (not user-tunable in v1, per §7), so account
-- count doesn't translate directly into thread or connection count.
data SyncWorkerPool = SyncWorkerPool
  { poolSize        :: !PositiveInt
  , maxConnections  :: !PositiveInt  -- global cap on concurrent provider connections
  }

data DomainError
  = MessageNotFound MessageId
  | InvalidTransition Event MessageState
  | RecipientListEmpty

data SyncError
  = UidValidityConflict MailboxId
  | RemoteObservationStale UTCTime
  | UnreconcilableFlagState MessageId
  | ImpossibleReconciliationKey MessageId
    -- ^ §19: a key `reconcile` folded over that matched neither
    -- `LocalSnapshot` nor `RemoteSnapshot` — provably unreachable given
    -- `reconcile` builds its key set from `Map.keysSet local <>
    -- Map.keysSet remote`, kept as a named constructor rather than a
    -- partial match or a silently-dropped `Nothing`, per this section's
    -- own rule against escape hatches

data CommandError
  = NoSelection
  | AmbiguousTarget (NonEmpty MessageId)
  | InvalidInCurrentPane UserInput

-- | Used by §7 (wizard), §20 (provider adapters), §27 (refresh race).
-- Distinguishing ExpiredCredentials from network failure is what lets
-- AuthDone/refreshToken stop retrying instead of looping forever.
data AuthError
  = CredentialsRejected
  | ExpiredCredentials
  | AuthNetworkFailure
  | AuthProviderError Text

-- | Used by §7, §20 (fetchDelta/sendMessage). Transient is retry-eligible
-- under §19's backoff policy; Permanent and ProtocolViolation are not.
data ProviderError
  = ProviderTransient
  | ProviderPermanent Text
  | ProviderProtocolViolation Text

sumMessages :: [Message] -> MessageCount
sumMessages = foldl' (\n _ -> n + 1) 0   -- not a custom `go`


-- Signatures found only in non-haskell (```text) fences:
fetchDelta :: SyncCursor -> ProviderSession -> IO (Either ProviderError RemoteDelta)

-- Stub bodies for signature-only declarations (spec gives no implementation)
apply = undefined
bm25 = undefined
command = undefined
commandsFor = undefined
decodeCharset = undefined
discoverProvider = undefined
evaluateRules = undefined
execute = undefined
fetchDelta = undefined
lexQuery = undefined
loadConfig = undefined
markRead = undefined
matches = undefined
messageReferences = undefined
mkConflict = undefined
mkEmailAddress = undefined
mkSubject = undefined
nextAttempt = undefined
normalizeAddress = undefined
normalizeReplySubject = undefined
parseMessage = undefined
parseQuery = undefined
parseQueryLive = undefined
parseRfcMessageId = undefined
planQuery = undefined
quoteBody = undefined
refreshToken = undefined
renderInbox = undefined
replyTo = undefined
resolveRecipients = undefined
resolveReference = undefined
scoreCandidate = undefined
sendMessage = undefined
stepWizard = undefined
threadHeaders = undefined
threadMessages = undefined
toEnvelope = undefined
toMessage = undefined
transition = undefined
transitionScreen = undefined
validateConfig = undefined
validateMessage = undefined
view = undefined
wouldCreateCycle = undefined
