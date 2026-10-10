# Owl — Master Engineering Specification

> **A simple, exceptionally well-engineered terminal email client written in Haskell.**
> Email is complicated. Owl isn't.

This document supersedes the earlier vision doc, architecture doc, and phase-wise plan by consolidating them. It is the single reference for building Owl. Part I is product. Part II is architecture. Part III is the phased build plan. Part IV is the engineering standard everything above is held to. If a decision here conflicts with an earlier draft, this document wins.

---

# PART I — PRODUCT

## 1. Vision

Owl competes on **better defaults, simpler configuration, coherent behaviour, and exceptional implementation** — not feature count.

> **The power and efficiency of NeoMutt without NeoMutt's configuration burden.**

A user should be able to: `install → enter email → authenticate → use`. Owl detects the provider and handles IMAP, SMTP, OAuth, folders, tokens, and synchronization internally. Users configure **preferences**, not infrastructure.

## 2. v1 Scope

**In:** IMAP, SMTP, OAuth/device auth where supported, multiple accounts, inbox/folders, threading, local mail store, synchronization, search, read/unread, archive/delete/move, labels/tags where supported, compose, reply/forward, attachments, offline reading, address book, contact groups, recipient autocomplete, simple configuration, keyboard-first TUI, structured diagnostics.

**Explicitly out:** GUI, web client, mobile client, calendar, task manager, CRM, AI assistant, plugin ecosystem, scripting language, feature parity with Outlook, contact photos/avatars, elaborate theming, a planned "v2," large numbers of provider-specific features, a generalized JMAP abstraction before it's needed, PGP/S-MIME encryption and signing (v1 reads and sends plaintext/HTML MIME as-is; an encrypted message renders as an opaque attachment, never decrypted content).

## 3. The Mail Model

Owl presents one provider-independent model — `Account, Identity, Person, Address, Contact, Message, Thread, Mailbox, Label, Attachment, Draft, Search, Rule` — and providers (Gmail, Microsoft, generic IMAP, JMAP, Maildir) are adapters into it. The user interacts with mail concepts, never protocol concepts.

## 4. Authentication

Delegated to the provider: OAuth, device authorization, password auth, or an external credential provider. 2FA, passkeys, TOTP, and hardware keys stay outside Owl. Tokens use OS credential storage where available.

## 5. Offline-First

```text
Provider ↕ Synchronization ↕ Local Mail Store ↕ Search Index ↕ Owl
```

Fast startup, local search, offline reading, offline composition, queued operations, background sync, automatic recovery. Synchronization requires no user management.

## 6. Diagnostics

Operations have explicit states: `Pending → Running → Succeeded`, or `Running → Failed → Retry`. Errors state what happened, what remains safe, and what happens next — never a bare stack trace or protocol code:

```text
Archive failed

  ✓ Message remains safely on server
  ✗ Local synchronization failed

  The operation will be retried automatically.
```

This is a UI-visible expression of the error taxonomy in §28 — every `SyncError`/`CommandError`/`IOError`-shaped value that reaches the user must be rendered through this three-part shape, not printed as-is.

## 7. Configuration & First Run

Configuration is Owl's principal advantage over NeoMutt:

```text
$ owl
Email address: user@example.com
Discovering server settings (DNS SRV/MX)...
Authenticating...
✓ Account configured
✓ Mailboxes discovered
✓ Synchronization started
```

User-facing config describes preferences, not protocol internals:

```toml
[ui]
theme = "dark"

[account.personal]
email = "user@example.com"
```

It must not expose IMAP URLs, SMTP mechanisms, OAuth tokens, or folder internals unless the user deliberately opts into configuring a generic backend.

```haskell
loadConfig     :: ConfigSource -> IO (Either ConfigError Config)
validateConfig :: RawConfig -> Either ConfigError Config
```

`Config` is opaque after validation.

**Auto-discovery.** Rather than asking for hostnames and ports, Owl derives them from the email address's domain — DNS SRV first (RFC 6186), falling back to MX plus known-provider heuristics. This is inherently an effect (a real DNS lookup), so — unlike a pure validator — it lives in `IO`, not `Either`:

```haskell
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
```

If discovery is ambiguous, Owl returns an explicit choice rather than guessing.

**Secrets.** Owl never writes a token or password to a plaintext file. Secret storage is an algebraic interface over the OS's native store (Keychain on macOS, Secret Service/libsecret on Linux, Credential Manager on Windows):

```haskell
data KeyringHandle m = KeyringHandle
  { storeSecret  :: AccountId -> ByteString -> m (Either KeyringError ())
  , loadSecret   :: AccountId -> m (Either KeyringError ByteString)
  , deleteSecret :: AccountId -> m (Either KeyringError ())
  }
```

**Onboarding wizard.** If no account is configured, Owl enters a pure state machine that drives the prompts above and immediately initializes local storage on success — total over its input, exactly like `apply` (§24) and `transition` (§19), and unit-testable without a terminal or a network:

```haskell
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
```

**Gate:** a fresh user configures a supported account without understanding mail protocols, and no secret is ever written to a plaintext file.

---

# PART II — ARCHITECTURE

## 8. Architectural Thesis

Owl is not architected around screens (Inbox, Message, Compose, Settings).

> **Owl is a local email algebra: a strongly typed mathematical model of mail, with protocols and the terminal UI acting as boundaries around that model.**

```text
Problem → Mathematical model → Relevant algorithm/data structure →
Complexity analysis → Haskell representation → Dense, terse implementation →
Tests proving properties
```

No algorithm is invented ad hoc where a named, established one applies (JWZ threading, Pratt parsing, BM25, snapshot reconciliation, bounded exponential backoff — see §14–§18). Choosing the relevant algorithm comes first; idiomatic Haskell expression comes second.

## 9. System Architecture

```text
                         ┌─────────────────────┐
                         │       USER          │
                         └──────────┬──────────┘
                                    │ keyboard input
                                    ▼
                         ┌─────────────────────┐
                         │   COMMAND MODEL     │  (§23 TUI)
                         └──────────┬──────────┘
                                    │ Events
                                    ▼
┌──────────────────────────────────────────────────────────┐
│                    OWL DOMAIN CORE  (pure)                 │
│                                                          │
│  Substates, composed not merged (§11)                     │
│      ├── MessageState   ├── MailboxState                   │
│      ├── ThreadState    ├── DraftState                     │
│      ├── ContactState   └── SyncState                      │
│                                                          │
│  Event Algebra (§24)        apply :: Event → Application → Either DomainError Application
│  Search Algebra (§15)       Query AST → Planner → Postings → Ranking
│  Threading Algebra (§14)    JWZ: Message-ID graph → Thread forest
│  Recipient Algebra (§16)    deterministic indexed ranking
│  Rules Algebra (§22)        Predicate → Action, structural Boolean eval
│  Reconciliation Algebra (§19) (LocalSnapshot, RemoteSnapshot) → Either SyncError SyncPlan
└──────────────────────────┬───────────────────────────────┘
                           │
                 ┌─────────┼─────────┐
                 ↓         ↓         ↓
              SQLite     Indexes    TUI
                 │         │         │
                 └─────────┼─────────┘
                    EFFECT BOUNDARY
                ┌──────────┴──────────┐
                ↓                     ↓
             IMAP/JMAP              SMTP
                └──────────┬──────────┘
                           ↓
                       INTERNET
```

Equivalently, built inside-out — this is also the dependency order and the recommended build order (§25):

```text
Pure Domain Core (Identity · Message · Contact)
      ↓
Threading · Search · Rules
      ↓
Sync State Model
      ↓
Provider Adapters
      ↓
Local Persistence
      ↓
Application Services
      ↓
TUI
```

**Architectural rule:** the core never knows that IMAP, SMTP, OAuth, SQLite, or a terminal exists. This diagram describes responsibilities and boundaries, not mandatory one-to-one modules.

## 10. Domain Vocabulary

Newtypes first; GADTs, phantom types, and refinement types only when a concrete invariant can't be expressed more simply.

```haskell
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
```

`MessageId` is built on `LocalId`, not on raw `Text` — every index, event, and store lookup keyed by `MessageId` is therefore keyed by Owl's own identity, never by anything an untrusted source (a wire-format `Message-ID` header, an IMAP UID) can hand it directly. §13 defines why.

```haskell
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
```

These remain intentionally abstract here — `Draft` gets its fields defined in §21, `Person`'s shape is sketched in §16, and the rest (`Account`, `Identity`, `Address`, `Contact`, `Thread`, `Mailbox`, `Label`, `Attachment`) are left for implementation where this document doesn't need to pin the shape down. A bare `data X` above should never be paired with a second, conflicting `data X = X { ... }` elsewhere without removing this line, the way `Message` was.

Closed domains (providers, flags, mailbox kinds) are sum types, never strings. Smart constructors return `Either`; there is no primitive obsession and no opaque `Text`/`Int` standing in for a domain concept with real invariants.

**Multi-account identity.** `MailboxId` and `ThreadId` are minted by Owl at discovery/threading time from a provider-supplied name *plus* the owning `AccountId` (e.g. account `personal`'s "INBOX" and account `work`'s "INBOX" are discovered as two distinct `MailboxId`s from the start) — never derived from the raw provider folder name alone. This is what lets `Map MailboxId ...`/`Map ThreadId ...` structures (`MailboxState.mailboxCatalog`, §17's indexes) hold every account's data in one flat map without a compound key, consistent with "multiple accounts" being in v1 scope (§2). `Message` (§12) carries its owning `accountId` directly, for the same reason.

**Gate:** invalid domain states cannot be constructed through the public API.

## 11. State Composition: Substates Are Separate, Composed Explicitly

Email contains several distinct state spaces — `MessageState, MailboxState, SyncState, DraftState, ContactState` — plus UI and transport concerns that are *not* domain state at all. Collapsing all of it into one giant record creates unnecessary coupling and is the single decision most likely to determine whether the codebase stays near 10k lines or drifts to 25k.

**Decision:** there is no monolithic state type. Each space is its own type; the application composes them:

```haskell
data Application = Application
  { messages  :: !MessageState
  , threads   :: !ThreadState
  , contacts  :: !ContactState
  , mailboxes :: !MailboxState
  , drafts    :: !DraftState
  , sync      :: !(Map AccountId SyncState)  -- one account's sync status can't stand in for another's, see §19
  }
```

`UIState` (cursor, scroll, active pane) belongs to the TUI layer (§23). `TransportState` (sockets, in-flight IMAP tags) belongs to the effect-boundary worker thread (§27). Neither is a field of `Application`.

Access goes through lenses scoped to each substate (`messagesL :: Lens' Application MessageState`), never through direct whole-record update. Event handlers (§24) take only the substate they can legally touch, with a thin dispatcher doing field selection — so a change to `SyncState`'s shape can't force a recompile-and-reason pass over message-read logic, and a property test for `MessageState` transitions doesn't need to construct a full `Application`.

`MailboxState` holds mailbox/label *membership* as its own canonical relation, not a field embedded on `Message` — a message can belong to several mailboxes at once (a Gmail-style "Inbox" + a custom label, or a JMAP mailbox with more than one parent), so membership must be multi-valued, not a single `MailboxId` per message:

```haskell
-- | The canonical mailbox-membership relation. Multi-valued deliberately:
-- a message can be In("Inbox") and In("Work") simultaneously.
newtype MailMembership = MailMembership (Map MessageId (Set MailboxId))

data MailboxState = MailboxState
  { membership     :: !MailMembership
  , mailboxCatalog :: !(Map MailboxId MailboxMeta)  -- names, kind, hierarchy
  }
```

`LabelId` (§10) remains a separate identity space for now rather than being folded into `MailboxId` — whether labels and mailboxes should unify into one relation is a real open question this document doesn't resolve, not something quietly assumed away.

## 12. Message Boundary

The trusted boundary between untrusted wire representation and Owl's domain:

```text
Bytes → RFC/MIME parser → RawMessage → charset-decode → normalize → ValidatedMessage → Owl Message
```

```haskell
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
```

Internationalized addresses (`EmailAddress`, §10) follow the applicable IDNA/UTF-8 address standards rather than being silently truncated or ASCII-mangled. Display of mixed-script or bidirectional text (sender names, subjects, filenames) must not be allowed to visually misrepresent the underlying value — this is a spoofing surface, not just a rendering nuance.

Use mature MIME/RFC libraries for protocol parsing; Owl owns translation and Owl-specific invariants, not a reimplementation of RFC 5322/2045. For recursive MIME structures, apply **one explicit depth/size bound** across every recursive stage — this is a security boundary (adversarial nesting), not just a style preference.

The same class of boundary applies to attachments as a whole: cap total attachment count and cumulative attachment size per message, and decode attachment content (especially anything compressed) as a bounded stream that aborts on exceeding a hard byte ceiling rather than buffering fully before checking. A message with tens of thousands of tiny attachments, or one whose content expands from kilobytes to gigabytes on decode, is the same denial-of-service shape as unbounded MIME nesting and is closed by the same discipline.

Untrusted content leaving this boundary carries no execution privilege of its own: HTML is reduced to a restricted, non-active display form (no scripts, no remote-resource fetch by default) rather than rendered as-is; a URL's displayed text and its actual target are surfaced as distinct values so one can never silently stand in for the other; an attachment's filename is a display string only and is never used to derive a filesystem path (write targets are Owl-generated, never wire-supplied). Because the TUI writes message content directly to a terminal, header and body text are stripped of ANSI/control escape sequences before display — an adversarial `Subject` is exactly the same class of untrusted input as adversarial HTML, and gets the same treatment: sanitized at this boundary, never passed through.

```haskell
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
```

`recipients` is a plain list, not `NonEmpty` — a received message can legitimately have zero visible recipients: a message delivered purely via Bcc has no `To`/`Cc` at all by the time Owl sees it, since Bcc addresses aren't preserved in the headers of the copy each recipient receives. Making this `NonEmpty` would make a real, valid input unrepresentable, which is the opposite of §11's rule. `NonEmpty` is the correct constraint only at the point Owl *constructs* an outgoing submission, where "zero `RCPT TO` recipients" really is meaningless — see `OutgoingEnvelope` in §21. Every field addition must be justified by "this makes an illegal state unrepresentable, and this state really is illegal," not convenience.

**Tests:** malformed headers, malformed addresses, unusual-but-valid addresses, empty fields (including Bcc-only messages with no `To`/`Cc`), large messages, attachment-heavy messages, adversarial input, known prior-art failure cases (this is where real-world MIME horror stories from other clients' bug trackers earn their keep as regression fixtures).

**Gate:** untrusted input cannot enter the core as a trusted `Message` without validation.

## 13. Message Identity

An IMAP UID is not Owl's message identity.

```haskell
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
```

Equality on `Message` is equality on `messageId . identity` (§10, §12) — never on `rfcId`. `rfcId` is a secondary heuristic index for cross-mailbox duplicate and thread detection, scoped by `AccountId` rather than global — two different accounts can legitimately observe colliding `Message-ID` headers (a mailing-list message delivered into two mailboxes Owl manages, or two providers both echoing a non-unique id from a broken client), so the index key is `(AccountId, ValidatedRfcId)`, never the bare id. RFC `Message-ID` is not guaranteed unique, present, or well-formed even within one account, so it must never be a primary key. A `UIDVALIDITY` change invalidates every `ImapRef` scoped to it; the reconciler (§19) treats this as "no known remote refs for this mailbox," not as an error.

## 14. Thread Reconstruction

Threads form graphs/forests over `Message-ID`, `In-Reply-To`, and `References`. **Use the established JWZ threading algorithm** — do not invent a heuristic.

```text
Message-ID / In-Reply-To / References
      ↓
message containers
      ↓
dummy intermediate nodes (for referenced-but-missing messages)
      ↓
parent/child tree
      ↓
thread forest
```

```haskell
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
```

Threading operates within a single account's message corpus — `threadMessages` takes the `AccountId` explicitly and resolves every reference through it. Threads never span accounts, even if two accounts happen to receive copies of the same list message carrying the same `Message-ID`.

Build with `Map MessageId ...`, not repeated list scans. **Target: O(n log n)** for `n` messages.

Malformed or adversarial `References`/`In-Reply-To` headers can describe an actual cycle (`A` references `B`, `B` references `A`). Enforce the no-cycles invariant during construction, not after the fact:

```haskell
-- | Before linking a container as a child of a candidate parent, walk the
-- parent's existing ancestor chain. True means linking would create a cycle.
wouldCreateCycle :: ThreadBuildState -> MessageId -> MessageId -> Bool
```

Before linking a container as a child of a candidate parent, check `wouldCreateCycle`; if the would-be child already appears in the parent's ancestor chain, refuse the link and treat the container as a root instead. This is O(depth) per link, and JWZ trees are typically shallow, so it doesn't threaten the O(n log n) target.

**Invariants:** no duplicate message identity; no cyclic parent relation (enforced by `wouldCreateCycle` at link time, not by rejecting the input outright); every message belongs to exactly one resulting thread; parent/child relationships stay consistent even with adversarial input.

**Properties to test:** permutation invariance (thread result is independent of input order), missing references, duplicate references, missing intermediate messages, disconnected conversations, malformed references, large threads, adversarial/cyclic graphs. Benchmark scaling with message count.

**Gate:** threading is pure, deterministic, property-tested, and benchmarked.

## 15. Search Algebra

```haskell
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
```

Query language surfaced to the user:

```text
from:alice invoice
after:2026-08-01 has:attachment
from:alice subject:proposal
in:work has:attachment
"annual report"
```

**Parsing — Pratt parser**, not ad-hoc string splitting, so Boolean precedence (`NOT` highest, then `AND`, then `OR`) is unambiguous:

```haskell
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
```

Parser is **O(tokens)**. `parseQuery` is strict — `Left` on any incomplete input — which is correct for a submitted query, a saved search, or a rule definition, but wrong for search-as-you-type, where every keystroke before the query is complete is, by definition, incomplete input. `parseQueryLive` is the separate, lenient entry point for that one case.

Semantic definition — the reference truth any index-backed execution must agree with:

```haskell
matches :: Message -> Predicate -> Bool
```

Execution is separate from meaning:

```text
Query AST → Query planner → Index operations → Candidate set → Verification/ranking
```

The candidate set is capped at a fixed maximum before ranking/paging — an unbounded `OR` across common terms returning the whole mailbox is a resource-exhaustion shape, not a correctness feature.

Boolean composition is set algebra:

\[
Result(Q_1 \land Q_2)=Result(Q_1)\cap Result(Q_2) \qquad
Result(Q_1 \lor Q_2)=Result(Q_1)\cup Result(Q_2)
\]

Indexes, with execution complexity stated up front:

```text
MessageId → Message            O(1) average (HashMap)
Address → Set MessageId         O(log n) lookup, O(m+n) intersection
ThreadId → Set MessageId        O(log n) lookup
Date → ordered MessageIds       O(log n) range start, O(k) scan for k results
Flag / Mailbox → Set MessageId  O(log n) lookup
Term → PostingList (sorted [Posting], carries per-doc term frequency)  O(m+n) merge-intersect
AttachmentType → Set MessageId  O(log n) lookup
```

`And` compiles to a merge-intersection over postings ordered smallest-list-first, not a naive pairwise `Set.intersection` fold — for `from:x and has:attachment and after:2024`, that ordering is the difference between touching hundreds of ids and touching the whole `Address` index. **The planner's one job is choosing that order.** It is explicitly not a general cost-based optimizer.

`Before`/`After Day` predicates are evaluated in the user's configured local timezone: a `Day` boundary is converted to a `[localMidnight, nextLocalMidnight)` UTC range before touching the `Date` index, since `sentAt` is stored in UTC (§12) and a bare `Day` is otherwise ambiguous. This conversion happens once, in the query planner, not per-predicate.

`InMailbox` matches against the `MailMembership` relation (§11), not a single field on `Message` — since membership is multi-valued, a message can satisfy `InMailbox` for more than one `MailboxId` at once, unlike every other predicate here.

`InThread` matches against the `ThreadId → Set MessageId` index already listed above — no new index required.

```haskell
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
```

**Ranking — BM25 if ranking is enabled at all**, never an invented heuristic:

\[
score(D,Q)=\sum_{t\in Q} IDF(t)\,\frac{f(t,D)(k_1+1)}{f(t,D)+k_1(1-b+b|D|/avgdl)}
\]

```haskell
bm25 :: BM25Parameters -> DocumentStatistics -> QueryTerms -> MessageId -> Double
```

Ranking stays pure. v1 may omit ranking entirely if Boolean retrieval is sufficient — do not build a sophisticated retrieval engine merely for novelty; use an established indexing library if it adequately solves the problem.

**Gate:** parser, query model, and retrieval work independently of the TUI and provider.

## 16. Address Book & Recipient Resolution

The address book is part of the mail model, not a bolt-on CRM:

```text
Person
├── Name        ├── Groups
├── Email addrs ├── Notes
├── Organization└── Aliases
├── Phone
```

Provides recipient autocomplete, multiple addresses per person, groups, recent recipients, automatic correspondent discovery, provider sync where supported. **No photos, avatars, social profiles, or CRM functionality.** Distinguish `Contact`, `Correspondent`, `RecentRecipient`, `UnknownSender` — a person you've emailed isn't automatically a saved contact.

Recipient lookup starts with **deterministic indexed ranking**, not an opaque fuzzy-search heuristic:

```haskell
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
```

**Convention:** every rank field is lower-is-better (`0` = best possible match), so the derived `Ord` orders best matches first — `resolveRecipients` sorts directly by `scoreCandidate`, with no `Down` wrapper anywhere in the call chain. This direction is fixed here, once, rather than left for each call site to infer.

Score on exact address, exact name, prefix, alias, recency, frequency, with a stable `PersonId` tie-breaker so results never depend on incidental map/list order. Add trigram/fuzzy matching only if benchmarks and real usage justify it — not preemptively.

**Gate:** recipient resolution is deterministic, pure, and property-tested.

## 17. Derived Indexes

Search and thread indexes are **derived materializations**, never independent sources of truth:

\[
Index = f(Application)
\]

```text
Application
   ├→ SQLite (canonical)
   ├→ Search Index
   └→ Thread Index
```

Each `Event` (§24) produces a small, explicit `IndexDelta` derived structurally from its constructor — e.g. `MessageMoved mid src dst` touches exactly the `Mailbox` postings for `src` and `dst`, while `MessageLabeled`/`MessageUnlabeled` touch exactly one mailbox's postings, since each adds or removes a single `MailMembership` entry without touching any other mailbox the message belongs to — so incrementality is enforced by the type of the update function, not a hoped-for optimization applied later. The `Mailbox → Set MessageId` search index (§15) is itself a derived view over the canonical `MailMembership` relation (§11), not an independent structure — since membership is multi-valued, the same `MessageId` can legitimately appear under more than one `MailboxId` key. For the search index specifically, the same delta also updates the affected term `Posting`s and `DocumentStatistics` (§15), since BM25 needs both maintained incrementally, not just presence/absence in a `Set`. If an index is corrupted, it is rebuildable from canonical state via the same `f`; rebuild-equals-incremental is a tested property (§32), not an assumption.

Because most events touch only a subset of the derived indexes — `MessageRead`/`MessageUnread` change no postings and no thread edge at all — `IndexDelta` says so explicitly rather than carrying an always-present, sometimes-empty update for every index:

```haskell
data IndexDelta = IndexDelta
  { searchDelta :: !(Maybe SearchIndexDelta)  -- Nothing: this event has no postings/DocumentStatistics change
  , threadDelta :: !(Maybe ThreadIndexDelta)  -- Nothing: this event doesn't change thread structure
  }
```

§27's runtime state keeps the search index and thread index in their own `TVar`s specifically so this distinction matters at runtime: an event whose `IndexDelta` has `searchDelta = Nothing` never writes the search index's `TVar` at all, and so never contends with a concurrent reader of it.

Indexes are **persisted** alongside SQLite (own tables or a sidecar store), not rebuilt from scratch on every process start. Cold start loads them and applies only the `IndexDelta`s for events since the last clean shutdown, tracked via a `lastIndexedEventId` watermark. Full rebuild-from-canonical-state (the `f` above) is the *recovery* path, used when corruption is detected — never the steady-state startup path; the <150ms cold-start budget (§33) assumes load-and-catch-up, not a full rebuild.

Combined on-disk size of SQLite plus indexes is a configured ceiling, not left unbounded — exceeding it is a policy decision (oldest-synced-message eviction, or surfacing the condition to the user), never a silent fill-the-disk failure mode.

## 18. Local Persistence

SQLite is a persistence representation, not the conceptual model:

```text
Haskell Domain → Persistence model → SQLite
```

> **SQLite is the durable canonical representation; derived indexes are rebuildable materializations.**

The store is a repository over the Owl model, with query planning separated from execution:

```haskell
data StoreQuery = GetMessage MessageId | Search Query | ListMailbox MailboxId

planQuery :: StoreQuery -> Either StoreQueryError StorePlan
```

Hidden behind a narrow handle so the domain never imports the concrete database implementation, and an in-memory implementation can stand in for tests:

```haskell
data StoreHandle m = StoreHandle
  { loadMessage    :: MessageId -> m (Either StoreError Message)
  , saveMessage    :: Message   -> m (Either StoreError ())
  , searchMessages :: Query     -> m (Either StoreError (Set MessageId))
  }
```

Transactions preserve domain invariants atomically. Store accounts, messages, threads, mailboxes, flags, labels, contacts, sync metadata. Use an established embedded database rather than writing one.

The schema carries an explicit version number; a migration runs inside a transaction and either fully applies or leaves the prior version intact — never a partially-applied schema. v1 ships a single schema version with no migrations yet required; the version field exists from the start so the first real migration is additive, not a retrofit.

**Gate:** storage preserves domain invariants and can be replaced by an in-memory test implementation.

## 19. Synchronization as Reconciliation

Not `download → update → upload`. Reconciliation of two observations:

\[
R : (L,R) \rightarrow \Delta
\]

```haskell
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
```

The core compares stable identities, versions/cursors, and relevant message state, and produces a plan — it performs no network or database effects. **Target: O(local + remote)** with indexed identities. Genuine invariant violations in the input (e.g. a snapshot claiming one `UID` maps to two different `MessageId`s) surface as `Left SyncError`; ordinary per-message conflicts remain the `Conflict` constructor inside a successful `Right SyncPlan`.

`RemoteObservation` must derive `Eq` — `classify` (below) distinguishes "baseline still matches current remote" from "remote has moved on" by comparing two `RemoteObservation` values directly, so equality here isn't optional plumbing, it's load-bearing for `NoChange` vs. `Pull`/`Push`.

`LocalSnapshot` and `RemoteSnapshot` are two-way by name but three-way in what they actually carry per message — a flat diff of "local" against "remote" can't distinguish *"the remote changed since I last looked"* from *"I made an offline edit that hasn't round-tripped yet."* Both matter and call for different decisions, so `LocalSnapshot` records them separately instead of merging them into one opaque blob:

The naive shape here is a record of two `Maybe`s, but that makes a fifth, meaningless state representable: `LocalRecord Nothing Nothing` — "no known remote baseline and no pending edit" — which carries no information and should never exist as a map entry at all (§11's rule, applied to the reconciler's own input). `LocalRecord` is instead a closed sum over exactly the three states that mean something:

```haskell
data LocalRecord
  = KnownRemote            !RemoteObservation  -- synced before; no local edit since
  | PendingEdit             !Event             -- originated locally; never observed remotely
  | KnownRemoteWithPending  !RemoteObservation !Event  -- synced before, then edited locally, not yet pushed

type LocalSnapshot  = Map MessageId LocalRecord
type RemoteSnapshot = Map MessageId RemoteObservation
```

`reconcile` folds over `Map.keysSet local \`Set.union\` Map.keysSet remote` — so per key, `Map.lookup` against each snapshot gives `Maybe LocalRecord` and `Maybe RemoteObservation` independently. The original two-argument `reconcileOne` took a bare `RemoteObservation` (not `Maybe`) for "current remote," which makes server-side deletion — a key present in `LocalSnapshot` but absent from `RemoteSnapshot` — impossible to express; the function was partial exactly where deletion detection needed it to be total. It's split into a total merge and a total classification, neither of which needs a wildcard case:

```haskell
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
```

`mkConflict`'s remote-observation argument is `Maybe RemoteObservation`, not a bare `RemoteObservation` — `EditUnderDeletion` is a genuine conflict (a local edit against a message the server deleted) with no current remote state to attach to it, so `SyncConflict` must be constructible without one:

```haskell
mkConflict :: MessageId -> Event -> Maybe RemoteObservation -> SyncConflict
```

Server-side deletion (`RemoteDeleted`) and edit-vs-deletion (`EditUnderDeletion`) were both unrepresentable in the original two-argument `reconcileOne`, since its `currentRemote` parameter had no way to say "no longer present." A message with a known baseline, no pending edit, and no current remote observation is now `DeleteLocal` rather than something the reconciler couldn't see; a pending edit against a message the server deleted is now a `Conflict` rather than being lost entirely (a plain `DeleteLocal` here would silently discard the user's local edit).

For an initial sync of a large mailbox, `LocalSnapshot`/`RemoteSnapshot` are windowed by UID range or by mailbox rather than materialized whole. `SyncPlan`'s `Semigroup` instance lets per-window results compose associatively, so `reconcile` runs per chunk with bounded memory instead of needing the entire mailbox in memory at once; the properties below hold per chunk and therefore hold for the combined result.

This composition is sound only because a `SyncDecision` is scoped to a single `MessageId`/`MailboxId` and never depends on data outside its own window. A message that moves mailboxes mid-initial-sync is observed as two independent per-mailbox windows — a `Pull` in the destination window's `RemoteSnapshot`, and either `NoChange` or a stale-looking absence in the source window depending on timing — and both are safe to apply independently because §13's identity model means the same `MessageId` is recognized in both windows rather than treated as two unrelated messages; `execute` applying both decisions converges on the same end state regardless of window order. If a future decision kind ever needs context from outside its own window (e.g. a cross-mailbox merge), it no longer fits this `Semigroup` composition, and that is a signal to revisit chunking rather than to add shared state between windows.

Execution is separate and is where retries/idempotency live:

```haskell
execute :: SyncPlan -> IO SyncOutcome
```

State transition is pure and explicit:

```haskell
data SyncState = NotSynced | Syncing | Synchronized | NeedsRetry SyncFailure

data SyncEvent = SyncStarted | RemoteChanged | LocalChanged
               | SyncCompleted | SyncFailed SyncFailure

-- | Operates on one account's current state; the caller (which already
-- knows which account produced the event, per §27's per-account workers)
-- applies the result at that AccountId's key in Application.sync (§11) —
-- transition itself stays a plain one-account state machine, not a map.
transition :: SyncState -> SyncEvent -> Either SyncError SyncState
```

Retry is **bounded exponential backoff**, never unbounded recursion:

```haskell
data RetryPolicy = RetryPolicy { maxAttempts :: PositiveInt, backoff :: Attempt -> Duration }
nextAttempt :: RetryPolicy -> Attempt -> Maybe Duration
```

**Properties, each its own test, checkable without a live server because the reconciler is pure:**

- **Idempotence under no-op remote observation:** `reconcile L R` yields a plan containing only `NoChange` once `R` reflects exactly the last plan Owl executed.
- **UIDVALIDITY-reset safety:** a new `UIDVALIDITY` invalidates every previously-known `ImapRef` in that mailbox and re-derives mappings from `Message-ID`/heuristic matching — never spurious deletes.
- **Rename-as-move:** a mailbox rename produces a `MoveMailbox` decision, not `DeleteMailbox` + `CreateMailbox`, which would orphan message state.
- **New arrival is never a conflict:** `toReconciliationInput Nothing (Just cur)` always yields `RemoteArrival cur`, and `classify` always turns that into `Pull` — a message Owl has no history for cannot have "diverged" from anything.
- **Remote deletion is detected, not silently dropped:** `toReconciliationInput (Just (KnownRemote _)) Nothing` yields `RemoteDeleted`, and `classify` always turns that into `DeleteLocal` — a message present in `LocalSnapshot` with a known baseline but absent from `RemoteSnapshot` must produce a decision, never be skipped because it isn't a key in `RemoteSnapshot`.
- **Edit-vs-deletion never discards the edit:** `toReconciliationInput (Just (KnownRemoteWithPending _ e)) Nothing` yields `EditUnderDeletion`, and `classify` always turns that into `Conflict`, never `DeleteLocal` — a pending local edit is surfaced for resolution, not silently overwritten by a server-side delete.
- **`reconcileOne` is total over every reachable input:** generate all seven `ReconciliationInput` constructors directly (rather than only via `toReconciliationInput`) and assert `classify` pattern-matches every one without relying on the `otherwise` guard branches masking a missed case.

`RemoteState`/`RemoteSnapshot` is deliberately allowed to encode IMAP's real failure shapes (UIDVALIDITY resets, mid-sync renames) as data — the reconciler knows exactly the weirdness that changes what plan is safe to emit, and nothing about wire format, which stays in the provider adapter (§20). For IMAP specifically, the adapter uses UID-based state and CONDSTORE/QRESYNC when supported; provider-specific identifiers must never leak into the core.

**Tests:** interrupted sync, duplicate delivery, deletion, movement, flag changes, reconnect, retry, partial failure, concurrent changes.

**Gate:** sync planning and state transitions are testable without a network.

## 20. Provider Adapters & Protocols as Boundaries

Owl's internal sync model must not become an IMAP model:

```text
Owl Sync Model → { IMAP, JMAP } → RemoteState
```

JMAP is not a v1 requirement — do not build a generalized protocol abstraction prematurely; make the domain naturally protocol-independent and implement IMAP first, generalizing only when a second real implementation exists and duplication is observed (not anticipated).

```text
mailbox discovery → UIDVALIDITY/cursor → UID/flag/mod delta → RemoteDelta → pure reconciliation

fetchDelta :: SyncCursor -> ProviderSession -> IO (Either ProviderError RemoteDelta)
```

SMTP: translate the validated outgoing message to the mature SMTP library's representation; do not implement SMTP itself.

```haskell
-- | A connection lost after the SMTP payload was handed off is not the
-- same as a clean rejection — the message may have been accepted. That
-- ambiguity is represented explicitly, the same way §19 represents sync
-- ambiguity, rather than collapsed into a plain failure that would
-- invite a blind (possibly duplicate) retry.
data SendOutcome = Sent | SendOutcomeUnknown

sendMessage :: ProviderSession -> OutgoingEnvelope -> IO (Either ProviderError SendOutcome)
```

`OutgoingEnvelope` is defined in §21, at the boundary where a `Draft` becomes something SMTP-shaped — this is deliberately not the inbound `Message` type (§12): the two have different, non-interchangeable invariants (see §21 on why recipients are `NonEmpty` only here).

Authentication is a separate concern (`Authentication → Session → Provider adapter`). Use closed ADTs for Owl-owned finite cases and Handles for replaceable effectful implementations — do not create a universal provider typeclass merely because multiple providers exist. Start with IMAP + SMTP + one OAuth-capable provider.

**Gate:** Owl performs a real synchronization against the first supported provider.

## 21. Compose, Reply, Send

Reply construction is pure — SMTP is entirely outside these transformations:

```haskell
replyTo :: ReplyMode -> Identity -> Message -> Either ReplyError Draft

normalizeReplySubject :: Subject -> Subject
-- required: normalizeReplySubject (normalizeReplySubject s) == normalizeReplySubject s

threadHeaders :: Message -> Headers
quoteBody     :: QuoteStyle -> Body -> Body
```

```text
Draft
 ├── recipients
 ├── subject
 ├── body
 └── attachments
```

Derive reply-to-self, reply-all, `Reply-To` handling, mailing-list behavior, multiple identities, subject normalization, and threading headers all in pure code.

A `Draft`'s recipients are a plain list too, for the same reason as inbound `Message` (§12) — an in-progress draft can transiently have none. `NonEmpty` becomes the correct constraint only at the final step, turning a `Draft` into something SMTP can actually submit:

```haskell
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
```

**Autosave.** `DraftChanged` events update in-memory `DraftState` immediately, but must also reach durable storage on a bounded debounce (e.g. every 2s of typing idle, or every N `DraftChanged` events, whichever comes first) — independent of the undo stack (§24) and the TUI's redraw wake-up (§27). A crash mid-compose should lose at most the debounce window, never the whole draft. A `Left ProviderError` or `Right SendOutcomeUnknown` from `sendMessage` (§20) leaves the originating `Draft` in place rather than transitioning it to sent — only `Right Sent` retires the draft.

**Tests:** reply-to-self, reply-all, `Reply-To` precedence, mailing lists, multiple identities, attachments, subject idempotence, threading headers, failed sends, retries, `toEnvelope` rejecting a zero-recipient `Draft`, a send returning `SendOutcomeUnknown` leaves the `Draft` intact.

**Gate:** compose/reply/send works end-to-end.

## 22. Rules and Semantic Actions

```text
WHEN from:alice AND has:attachment
DO   label:documents, mark-read
```

```haskell
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
```

Evaluation is structural recursion over the closed `Predicate` type (§15) and produces semantic `Action` values — it performs no IO; execution belongs to the application/sync layer. If conflicting actions are possible (e.g. `Archive` and `MarkUnread` both firing), define explicit conflict semantics before implementation rather than letting incidental list order decide.

**Gate:** rule evaluation is pure and property-tested.

## 23. TUI as a Projection

The TUI owns no domain state and contains no mail-domain logic:

```text
TUI → Application commands → Domain operations → Handles → Adapters
```

```haskell
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
```

A command transition is O(1) apart from operations explicitly delegated to the application layer. `UIState` (cursor, scroll, active pane, in-progress compose buffer before it becomes a `Draft`) is threaded alongside `Application` but excluded from it (§11) — mixing it in would make every domain property test carry irrelevant UI fields.

`command` and `view` are pure, so most TUI behaviour is unit-tested as `UserInput -> Events` and `Application -> Screen`, with no terminal required.

`InboxView` is constructed as a bounded viewport — the current scroll offset plus roughly two screens of rows — computed via the `Date`-ordered index's O(log n) range-start and O(k) scan (§15), never as a materialization of the full result set. For a 200k-message mailbox this is what keeps `renderInbox` inside the <5ms navigation budget (§33); it is a constraint on how `InboxView` is built, not an incidental implementation detail.

**Screens:** Inbox/mailbox, Message/thread, Search, Compose, Address lookup, Account/status, Help.

**Keyboard vocabulary (`InboxScreen`/`ThreadScreen`):** `j/k` navigate · `Enter` open · `r` reply · `f` forward · `c` compose · `a` archive · `d` delete · `u` unread · `z` undo (§24) · `s` search · `q` back/quit · `?` help.

Bindings are scoped per screen, not global — `r`/`f`/`a`/`d` are meaningless inside `ComposeScreen`, and a compose text buffer needs its own bindings that would otherwise collide with navigation keys like `j`/`k`. `transitionScreen`'s valid command set is explicitly partitioned per screen and property-tested:

```haskell
commandsFor :: Screen -> Set Command
```

a `Command` not in `commandsFor currentScreen` is a `CommandError`, never silently ignored or reinterpreted. `?` renders only the bindings valid for the *current* screen. Keyboard-first does not mean requiring memorization — actions must be discoverable (visible hints, context-sensitive `?` help). Do not build a generalized command/plugin framework.

**Gate:** the TUI can be replaced without changing domain logic.

**Accessibility:** keyboard-only operation is not an accessibility fallback, it is the only interaction model (above) — there is no mouse-only affordance to fail to replicate. Status and diagnostics (§6) are conveyed through symbols and text (`✓`/`✗`), never color alone, and the renderer respects the terminal's own color/contrast configuration (e.g. `NO_COLOR`) rather than imposing its own palette. Text size and contrast are the terminal emulator's responsibility, not Owl's, by construction of building on the terminal rather than a custom renderer — that scope boundary is deliberate, not an oversight. Screen-reader compatibility depends on the terminal emulator and its assistive-tech integration; Owl's obligation is to emit plain, linearly-readable text output rather than layout that only makes sense visually (e.g. no meaning conveyed purely through cursor position or spatial alignment that isn't also stated in text).

## 24. Event Algebra

```haskell
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
```

\[ S_{n+1} = apply(e_n,S_n) \]

`apply` is **total over its input type** — every constructor has a defined result for every reachable `Application`, even if `Left`. `-Wincomplete-patterns` is a build failure (§30). The event algebra does not imply full event sourcing: SQLite stores current `Application` state directly (§18), not a replayable log; events are the computational vocabulary `apply` consumes, not persisted history. Delete is soft (`MessageDeleted`/`MessageRestored`), consistent with the "message remains safely on server" diagnostics example in §6.

`MessageMoved mid src dst` is exactly the composition of removing membership in `src` and adding membership in `dst`, kept as its own constructor rather than requiring two separate `MessageUnlabeled`+`MessageLabeled` events — an ordinary IMAP folder move is atomic, and undo (§24, below) should invert it as one action, not two independently-undoable ones. `MessageLabeled`/`MessageUnlabeled` exist for the general Gmail/JMAP case where a message gains or loses one membership without a corresponding "from."

**Enforcement, not just principle:** a simple operation should stay simple —

```haskell
markRead :: MessageId -> Application -> Application
```

— and should not become a chain of command/intent/event/transition/projection/persistence abstractions unless the problem genuinely requires those boundaries. Before writing the general `Event`/`apply` machinery, implement `markRead`, `archive`, `moveMessage`, and `sendDraft` directly against `Application`, with no `Event` type in sight. Only after those four exist and their shared shape is visible should the `Event`/`apply` abstraction be introduced — by refactoring those four functions to fit it, not by designing the abstraction up front. If refactoring an operation into the event algebra makes it harder to read than the direct version, the direct version stays.

**Undo.** Destructive single-keystroke actions (`archive`, `delete`, `move`) need a recovery path. This is not event sourcing — no log is persisted — it's a small, explicitly-scoped, in-memory stack:

```haskell
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
```

`invertEvent` is necessarily partial — not every event is invertible — so `Nothing` is a legitimate result, not a bug to route around; the undo stack simply can't offer undo for that action. Bound to `z` (§23) rather than `u`, which is already `mark unread`.

---

# PART III — IMPLEMENTATION PLAN

## 25. Phased Build Order

Built inside-out (see §9); each phase gates the next. LOC figures are production-code estimates (tests are additional, budgeted in §31).

| Phase | Scope | Algorithm / Key Decision | Gate | Est. LOC |
|---|---|---|---|---:|
| 0 | Foundation — cabal project, CI, warnings, Hlint, Fourmolu, Weeder, Hspec, Hedgehog/QuickCheck, Criterion, Haddock | — | CI, lint, format, tests, benchmarks work before feature code | 100–250 |
| 1 | Domain vocabulary (§10) | Smart constructors, closed ADTs | Invalid domain states unconstructable | 500–700 |
| 2 | Message boundary (§12) | Staged parse → validate → domain | Untrusted input can't enter core unchecked | 600–800 |
| 3 | Thread reconstruction (§14) | JWZ threading | Pure, deterministic, property-tested, benchmarked | 600–900 |
| 4 | Address book & recipients (§16) | Deterministic indexed ranking | Deterministic, pure, property-tested | 400–600 |
| 5 | Search engine (§15) | Pratt parser + inverted index + optional BM25 | Parser/query model/retrieval work standalone | 700–1,000 |
| 6 | Local mail store (§18) | Transactional repository behind `StoreHandle` | Invariants preserved; swappable for in-memory test impl | 600–800 |
| 7 | Synchronization engine (§19) | Snapshot reconciliation + bounded backoff | Sync planning/transitions testable without a network | 900–1,200 |
| 8 | Provider adapters (§20) | IMAP (UID/CONDSTORE/QRESYNC) + SMTP + one OAuth provider | Real sync against first provider works | 700–1,000 |
| 9 | Compose/reply/send (§21) | Pure reply/quote/thread-header derivation | End-to-end send works | 500–700 |
| 10 | Rules (§22) | Structural Boolean evaluation | Rule evaluation pure, property-tested | 400–600 |
| 11 | TUI (§23) | Finite-state `Command`/`Screen` navigation | TUI contains no domain logic | 1,200–1,600 |
| 12 | Configuration & first run (§7) | Validated config pipeline, DNS SRV/MX auto-discovery, OS keyring, pure wizard state machine | Fresh user configures without protocol knowledge | 450–650 |
| 13 | Integration, hardening, release (§26) | Algorithm verification matrix, security review, perf review | E2E/security/property/regression/perf checks pass | — |
| 14 | 10k LOC audit (§31) | — | ≤10k LOC and engineering standard audit passes | — |

**Critical milestone:** by the end of Phase 7, Owl already has a pure mail domain, message validation, threading, address book, search, local storage, and sync planning — all testable without a terminal or real network. The TUI is a **consumer** of the model, never the place the model gets invented.

```text
Phase 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14
```

## 26. Integration, Hardening & Release (Phase 13)

**Algorithm verification matrix** — every algorithm names what it is; a different algorithm than the one specified here requires a documented reason:

| Component | Algorithm | Target |
|---|---|---|
| Threading | JWZ | O(n log n) |
| Query parsing | Pratt parser | O(tokens) |
| Boolean retrieval | inverted-index set operations | posting-list dependent |
| Ranking (if enabled) | BM25 | query-term/posting dependent |
| Recipient resolution | indexed lookup + deterministic ranking | candidate-set dependent |
| Sync planning | snapshot reconciliation | O(local + remote) |
| Retry | bounded exponential backoff | bounded attempts |
| UI navigation | finite-state transition | O(1) |
| Undo | bounded event-inversion stack | O(1) per undo, ≤10 entries |
| Background wake-up | STM blocking retry | O(1) amortized |

**End-to-end scenarios:** fresh install, multiple accounts, initial sync, offline startup, search, read, reply, compose, send, archive, delete, move, contact lookup, reconnect, auth renewal, failed sync.

**Threat model** (maintained from Phase 1 onward, not authored only at Phase 13): the trust boundary is everything entering at §12 (raw bytes from a provider), §20 (provider/OAuth responses), and rendered output at §23 (untrusted content reaching a terminal). Assets: stored credentials, message content, the local SQLite store. Adversary classes: a malicious or compromised mail server, a malicious message sender, a network attacker without valid credentials. Every item below is a concrete instance of one of these boundaries — this list is revisited whenever a boundary changes, not just before release.

**Security review:** credential/token handling, TLS usage, untrusted email parsing (§12), charset/encoding handling (§12), HTML/URL/attachment-filename policy (§12), terminal escape sequences (§12), resource exhaustion, filesystem paths, database integrity.

**Performance review:** initial indexing, search, thread reconstruction, sync planning, large-inbox rendering. Optimization requires evidence (a benchmark showing the regression/target miss), not intuition.

**Release record:** each release (including pre-1.0 milestones) is tagged with the source revision, dependency versions in use, current schema version (§18), the property/integration test results it shipped with, known limitations, and the outcome of the most recent security review above. This is a record kept alongside the release, not a new process invented at v1 — its absence is what makes "was this checked" unanswerable later.

---

# PART IV — ENGINEERING STANDARD

## 27. Concurrency Model

Owl has at least three concurrently-active concerns sharing state: the TUI event loop, a background IMAP `IDLE`/poll worker, and SMTP send.

**Decision:** domain state and its derived indexes are updated only through `apply`/`reconcile`-derived `STM` transactions, and — critically — no reader can observe `Application` out of step with the indexes it's about to query. If `SearchIndex`/`ThreadIndex` (§17) were updated separately from `Application` after a transaction commits, a search could return a just-archived message, or miss a message that just moved into the mailbox being searched.

That guarantee comes from STM's atomicity being scoped to a *transaction*, not to a single `TVar` — a `do`-block inside `atomically` that reads or writes several `TVar`s is exactly as atomic as one `TVar` holding a record with several fields; the guarantee doesn't require collapsing the state into one cell. Collapsing it into one `TVar` has a real cost the original design didn't price in: GHC's STM tracks conflicts per `TVar`, so bundling `Application`, the search index, and the thread index into one cell means *any* write — a background `MessageRead` touching one flag — conflicts with *any* concurrent reader of the bundle, including a keystroke-driven search over the other 199,999 messages that read never needed to touch. Splitting the state into per-substate `TVar`s, written together inside one transaction only when a given event's delta actually touches them, keeps the same cross-field consistency guarantee while letting unrelated readers and writers stop contending:

```haskell
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
```

A `SyncPlan` producing several events still applies them — `Application` and every index each event's delta actually touches — inside one `STM` transaction, so a reader never observes state and its indexes out of step, and the TUI never observes a half-applied sync batch; nothing about that guarantee changed. `TransportState` lives in the IO-bound worker thread that owns the connection (never in a `TVar`), exactly as `UIState` lives in the TUI layer (§11, §23). Only effect-boundary code touches `IO` directly; `apply`, `reconcile`, `matches`, `view`, and `command` stay pure and callable from `ghci` with no runtime setup.

**Redraw wake-up.** The sync worker mutates `RuntimeState` from its own thread; without an explicit wake signal, a completed background sync would sit invisible until the next keypress — a real regression against the "automatic recovery" promise (§5). The original design woke the render loop on a *structural* `Eq` check over the whole bundled record — meaning every redraw-eligibility check deep-compared an `InvertedIndex` and a `Map ThreadId ThreadForest`, an O(index size) cost paid on every wake check rather than once per actual change, and one that would only have gotten worse as `RuntimeState` grew more fields. A monotonic generation counter, bumped once per `applyM` transaction, replaces it: comparison is O(1), and no substate needs an `Eq` instance at all.

```haskell
awaitChange :: RuntimeState -> Word64 -> STM Word64
awaitChange rt lastSeenGeneration = do
  current <- readTVar (rsGeneration rt)
  if current == lastSeenGeneration then retry else pure current
```

This wakes the render loop exactly when committed state actually changes, decoupled from keyboard input; the render loop then re-reads whichever `TVar`s the current `Screen` needs via `readRuntimeSnapshot` or a narrower read.

**OAuth refresh race.** The sync worker and an interactive send can hit an expired token at the same time; several providers rotate refresh tokens single-use, so two concurrent refresh attempts can invalidate each other and lock the account out. Guard with a single-flight refresh per account:

```haskell
newtype RefreshGuard = RefreshGuard (TMVar (Maybe (Async (Either AuthError Token))))

refreshToken :: RefreshGuard -> Account -> IO (Either AuthError Token)
```

The first caller starts the refresh and records the in-flight `Async`; concurrent callers await that same `Async` instead of issuing their own request.

**Multi-account bounds.** `RefreshGuard` above is scoped per account, but scoping the *guard* per account says nothing about the *aggregate* cost of N accounts syncing at once — nothing in it stops an N-account install from opening N unbounded IMAP connections and N background poll threads simultaneously. Two bounds apply account-independently:

```haskell
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
```

An account whose worker is currently busy queues rather than spawning another thread; `maxConnections` is checked before a new IMAP/SMTP connection opens, independent of which account is asking.

## 28. Error Taxonomy

Errors are values below the effect boundary, never exceptions. Each pure subsystem gets its own closed error type:

```haskell
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
```

**No catch-all `OtherError Text` constructor, ever.** A new failure mode gets a named constructor — a stringly-typed escape hatch is exactly the kind of thing that's easy to add under deadline pressure and never removed, and it defeats modeling errors as data at all. Exceptions are reserved for genuinely exceptional non-domain conditions (disk full, OOM) and are caught only at the effect boundary, converted to a domain-shaped error before crossing back into pure code. Every user-visible error renders through the three-part diagnostics shape in §6.

## 29. Mathematical / Algorithmic Style

Semantic density is the goal, not code golf:

> The Haskell source should resemble the mathematical operation or algorithm it implements. A reader should recognize the operation from the expression without decoding implementation machinery.

```text
sum/product     → foldl'/foldMap        membership     → Set/Map lookup
mapping         → map                    aggregation     → foldMap
selection       → filter/mapMaybe        effectful map   → traverse
concatenation   → concatMap              optional branch → maybe
existence       → any                    error branch    → either
universality    → all                    tree recursion  → explicit structural recursion
```

**Rules:**

1. Use library combinators before writing recursion.
2. Use folds for reductions; `map`/`filter`/`concatMap` for ordinary transforms; `foldMap` when a `Monoid` expresses the aggregation naturally; `traverse`/`sequence` for effectful structural traversal.
3. Use pattern matching for algebraic structure, not manual dispatch.
4. Use recursion only when the algorithm is inherently recursive (tree traversal, parser structure, state-machine interpretation, thread-tree construction).
5. Prefer `Data.Map`/`Data.Set`/`Data.IntMap` and their algebraic operations over hand-written search/membership/accumulation.
6. Prefer `NonEmpty` and total APIs wherever non-emptiness is an invariant.
7. Do not introduce abstraction merely to look functional; do not expand terse code when the shorter form is clearer; do not sacrifice type safety or mathematical clarity to reduce line count.

**Recursion test** before writing a recursive function over a collection:

> Is this actually structural recursion, or is it a fold/map/filter problem?

```haskell
sumMessages :: [Message] -> MessageCount
sumMessages = foldl' (\n _ -> n + 1) 0   -- not a custom `go`
```

The desired codebase is **small + strongly typed + algorithmically rich + mathematically expressive + terse + total** — not merely short. Comments, Haddock, and blank lines are never used to hide complexity or artificially reduce the measured LOC (§31).

## 30. Non-Negotiables

Build-enforced, not style-guide-suggested:

- `-Wall -Wcompat -Wincomplete-patterns -Wincomplete-uni-patterns -Werror` project-wide. No silently-ignored pattern-match gap.
- No `Prelude.head`, `Prelude.!!`, `fromJust`, or other partial functions in domain code (§10–§24). Use `NonEmpty`, `Maybe`-returning lookups, or a named error constructor instead.
- No `IO` in `apply`, `reconcile`, `matches`, `view`, `command`, `threadMessages`, `resolveRecipients`, or `evaluateRules`. If one of these needs `IO`, that's a signal it's misplaced, not a signal to relax the rule.
- Every `Event` constructor added comes with an `apply` clause, an index-delta clause (§17), an explicit `invertEvent` case (`Just` or a documented `Nothing` — §24's undo stack must stay total over every constructor, not just the ones added first), and at least one property test touching it — all in the same change, not tracked follow-up.
- Every new field on any `Application` substate is justified against §11's rule: it makes an illegal state unrepresentable, or an already-shipped feature requires it. "Might be useful later" is not sufficient.
- Every algorithm names itself (§26's matrix). A different algorithm than the one specified requires a documented reason, not a silent substitution.

## 31. LOC Budget

**Hard v1 constraint:** ≤10,000 non-comment Haskell LOC, including tests. Comments, Haddock, blank lines, and external documentation don't count; tests do.

| Area | Production LOC |
|---|---:|
| Foundation | 200 |
| Domain model | 650 |
| Message boundary | 750 |
| Threading | 750 |
| Address book | 500 |
| Search | 900 |
| Local store | 700 |
| Synchronization | 1,100 |
| Provider adapters | 900 |
| Compose/send | 600 |
| Rules | 500 |
| TUI | 1,400 |
| Configuration | 600 |
| Integration/release | 300 |
| **Production target** | **~9,850** |

**Preferred envelope:** production ~7,500–8,000, tests ~2,000–2,500, total ≤10,000.

If the implementation exceeds the limit, in order: remove unnecessary features → remove speculative abstractions → collapse false generality → reuse established libraries → simplify the TUI → reduce provider scope. **Never** sacrifice correctness, representation safety, or architectural clarity to hit the number — this standard places those above brevity, unconditionally.

## 32. Testing Strategy

| Subsystem | Property | Ref |
|---|---|---|
| `apply` | Total over `(Event, Application)`; no pattern-match failure for any generated pair | §24 |
| Threading | Permutation invariance, missing/duplicate/malformed references, cyclic input | §14 |
| Recipient resolution | Deterministic ordering for any generated query/address-book pair | §16 |
| Query algebra | `matches m q` agrees with index-backed execution for all generated `(Message, Query)` | §15 |
| Index deltas | `applyDelta (indexOf app) (deltaFor event) == indexOf (apply event app)` | §17 |
| Reconciler | Idempotence, UIDVALIDITY-reset safety, rename-as-move, new-arrival-is-never-a-conflict, remote-deletion-is-detected, edit-vs-deletion-never-discards-the-edit, `classify` total over all `ReconciliationInput` constructors — each its own test | §19 |
| Rules | Evaluation is pure and total over the closed `Predicate` type | §22 |
| `command`/`view` | Pure round-trip: generated `UserInput` sequences never produce a `CommandError` for reachable `UIState`s the UI can construct | §23 |
| Undo | Where `invertEvent e = Just e'`, applying `e` then `e'` returns the prior `Application` | §24 |

Golden tests are reserved for what they're actually right for: rendered `Screen` output for representative states, and IMAP wire-format parsing against captured real-server transcripts — never a substitute for property tests on the pure algebras above. Integration tests against a real or `greenmail`-style local IMAP server cover what pure reconciler properties can't (actual network failure, partial responses in `execute`); they're deliberately few and slow. The fast, wide surface is the property suite.

**Fuzzing:** the property suite above tests the domain algebras against generated *valid* inputs; the untrusted-input boundary (§12's `parseMessage`/`decodeCharset`, the search query lexer/parser of §15, address parsing) is additionally fuzz-tested against malformed and adversarial byte sequences, since a parser being total over well-formed input says nothing about its behavior on arbitrary bytes from a network peer. A crash, hang, or unbounded allocation on fuzzer input at this boundary is a release blocker.

## 33. Performance Budgets

- Cold start to inbox rendered: **< 150ms** for a 50k-message local mailbox (SQLite + index *load*, not rebuild — no network; see §17 on persisted vs. rebuilt indexes).
- Interactive search keystroke-to-results: **< 50ms** for indexed predicates over 200k messages; full-text `body:` may fall back to a visible "searching…" state past this budget but must never block the event loop.
- `markRead`/`archive`/`moveMessage` (single message): **< 5ms** — on the critical path of ordinary keyboard navigation, so it must never introduce perceptible input lag.
- Incremental index update per event: **O(log n)** or better in mailbox size, matching §15's index table. Full rebuild is the fallback path, never the steady-state path.

These are design targets, checked at design-review time — a design that can't plausibly hit them (e.g. a full scan per keystroke) is a defect before it's a benchmark failure.

## 34. Definition of Done for v1

```text
install → enter email → authenticate → see mail → search → open a conversation →
find a contact → reply → compose → send → go offline → continue
reading/searching/composing → reconnect → synchronize automatically
```

...without the user learning IMAP, SMTP, OAuth, MIME, mailbox layouts, or synchronization mechanics.

Internally, everything above the effect boundary — domain, algorithms, invariants, state machines, search, threading, rules — is pure Haskell reachable through narrow effects from exactly two consumers: provider/store adapters and the TUI.

The final codebase is **small enough to understand as a whole, mathematically structured where possible, strongly typed throughout, and practical enough to be a genuinely useful email client.**

---

## 35. Final Principle

> **Model the actual problem mathematically. Select the algorithm that is appropriate to that problem — and name it. Represent its invariants in Haskell's type system. Use standard Haskell abstractions where they directly express the operation. Keep effects at the boundary. Keep the resulting architecture as small as the problem permits.**

The objective is not academic sophistication. It is that the implementation corresponds so closely to the problem that the code itself becomes a precise description of how email works.

```text
Problem → Model → Named algorithm → Types → Dense Haskell → Tested properties
   → Reliable, fast, keyboard-first email client, in ≤10,000 lines
```
