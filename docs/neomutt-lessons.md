# Lessons from Mutt / NeoMutt's three decades of bug reports

**STATUS: UNVERIFIED HYPOTHESES — CHECK AGAINST OUR CODEBASE BEFORE
ACTING.** Everything below came from reading NeoMutt's public issue
tracker and related sources. None of it is a statement about what Owl
currently does. Each item names the Owl function to inspect; inspect it
before believing the claim. Some are probably already handled, some
probably are not, and some may not apply to our architecture at all.

**Coverage: roughly twenty issues, from two searches.** Mutt dates to
1996; the real corpus is thousands of issues. This is a bias sample —
skewed toward crashes with backtraces, because those get titled and
linked well. Silent wrongness is systematically under-represented in
any bug tracker. See "Not yet surveyed".

---

## The meta-lesson, stated first because it recurs everywhere

From [#1189](https://github.com/neomutt/neomutt/issues/1189), the
maintainer, on why RFC-2047 header decoding broke against Microsoft
clients:

> *"I have coded the regexps to be strict regarding to RFC, and hoped
> that mailers around wouldn't mess with them. I was wrong apparently."*

**In email, strict conformance to the RFC is a bug.** Real senders emit
malformed headers constantly, and the client's job is to render them
anyway. Every parser we own should be asked: what does this do with
input that is *nearly* right? We already learned this once, the
expensive way, with `extractSentAt` and its five date formats. The same
question applies to every other parser we have.

---

## Class 1 — Crash classes our language choice should eliminate

Recorded as evidence, and as a prompt to confirm we are actually
collecting the benefit rather than assuming it.

| Issue | Failure |
|---|---|
| [#1747](https://github.com/neomutt/neomutt/issues/1747) | SIGSEGV — null mailbox pointer (`m=0x0`) reaching `mutt_monitor_add` |
| [#1886](https://github.com/neomutt/neomutt/issues/1886) | SIGSEGV — `SSL_CTX_free()` twice: once in an error `goto` cascade, once in socket close. **The crash is in the error handler, triggered by StartTLS being refused.** |
| [#2403](https://github.com/neomutt/neomutt/issues/2403) | SIGSEGV on startup when a configured folder does not exist — crash while handling the server's `NO [NONEXISTENT]` reply |
| [#3129](https://github.com/neomutt/neomutt/issues/3129) | SIGSEGV on send when the sent-mail folder equals the open mailbox |
| [#188](https://github.com/neomutt/neomutt/issues/188) | Crash via header-cache backend |

Note how many are **in failure paths**: TLS refused, folder missing,
connection dropped. The error handler is what crashes.

**CHECK:** that we have no equivalent escape hatches — no
`unsafePerformIO`, no `error` on reachable paths in `Owl.Provider.*` or
`Owl.Sync.*`. The build already bans partial `head` via `-Wx-partial`.

---

## Class 2 — IMAP and sync. Highest priority; this is what we build next

### 2.1 Connection loss and incomplete resumption

Reported at least three separate times, which makes it the single
best-attested defect class in the tracker:

- [#1248](https://github.com/neomutt/neomutt/issues/1248) — after
  reconnecting, NeoMutt sends `LIST` but **not** `SELECT`, leaving the
  UI on *"(no mailbox) [Msgs:0]"*. Reconnection was *incomplete*, not
  absent — the subtle failure, not the obvious one.
- [#1038](https://github.com/neomutt/neomutt/issues/1038) — after an
  IMAP timeout, commands fail with `BAD Please select a mailbox first`.
  The same bug from the server's side: the client believed a `SELECT`
  was still in effect when the connection had been reset.
- [#3152](https://github.com/neomutt/neomutt/issues/3152) — segfault
  after hours idle against Gmail when the server drops the connection.
  The reporter's expectation is a fair requirement to adopt verbatim:
  *"I expect it to keep running, reconnecting when necessary."*

**CHECK:** `Owl.Provider.IMAP.connectImap` opens a connection — does
anything notice it dying? Is there any disconnect/close function at
all? (Believed: no to both.)

**REQUIREMENTS for the sync loop:**
1. Detect connection loss rather than assuming liveness.
2. On reconnect, re-`SELECT` — not merely re-connect.
3. Re-read `UIDVALIDITY` and compare against `cursorUidValidity`
   *before* trusting any cached UID. We are well placed: `SyncCursor`
   carries it and `buildRemoteDelta` already reports
   `deltaUidValidityReset`. The logic to act on it does not exist.
4. A long-idle session must survive. Test by leaving it running for
   hours, not minutes.

### 2.2 Hierarchy delimiter is server-specific and must be discovered

[#2403](https://github.com/neomutt/neomutt/issues/2403) shows
`STATUS "[Gmail].Drafts"` returning `NO [NONEXISTENT] Invalid folder`
— the config assumed `.` as the separator where Gmail uses `/`.
[mutt-wizard#700](https://github.com/LukeSmithxyz/mutt-wizard/issues/700)
shows the mirror image: `mailbox name INBOX.bla contains server's
hierarchy delimiter`.

**CHECK:** `Owl.Provider.IMAP.discoverMailboxes` calls `IMAP.list` and
discards the `[Attribute]` field entirely, keeping only the name. The
delimiter is reported by `LIST` and we are throwing it away. Our
`inferMailboxKind` hardcodes `[Gmail]/Sent Mail` with a `/` — correct
for Gmail, an assumption everywhere else.

### 2.3 A missing or empty mailbox must not be fatal

Two distinct cases:

- **Nonexistent folder** ([#2403]): server replies `NO [NONEXISTENT]`.
  Must be a handled, named outcome.
- **Empty folder has no UIDVALIDITY.** Per
  [Nylas' IMAP troubleshooting](https://developer.nylas.com/docs/provider-guides/imap/troubleshooting),
  UIDVALIDITY errors are *"triggered on folders that contain no
  messages (and so have no UIDVALIDITY values)"*.

**CHECK — this one looks like a live bug in our code.**
`Owl.Provider.IMAP.getUidValidity` returns `Nothing` when the server
reports no UIDVALIDITY, and `runFetch` turns that into
`Left (ProviderProtocolError "server did not report UIDVALIDITY")`.
If an empty mailbox legitimately has no UIDVALIDITY, **we fail the
whole sync for that mailbox** rather than treating it as empty. Verify
against a real server and fix if confirmed.

### 2.4 Servers with unstable UIDVALIDITY exist

Nylas documents servers whose UIDVALIDITY changes constantly, and names
Amazon WorkMail specifically; their sync gives up after
`MAX_UIDINVALID_RESYNCS` consecutive resyncs. Their conclusion is
blunt: such servers *"are not supported"*.

**REQUIREMENT:** a UIDVALIDITY reset triggers a full resync. If that
happens every cycle, we loop forever re-downloading a mailbox. Needs a
consecutive-reset counter and a stop-with-diagnostic, not infinite
retry. Ours currently has neither.

### 2.5 Command discipline: servers will disconnect you

[#2021](https://github.com/neomutt/neomutt/issues/2021) — `BYE Too many
invalid IMAP commands`. The log shows `DONE` pipelined together with a
burst of `STATUS` commands, repeatedly, until the server gave up.

**REQUIREMENT:** if we ever implement IDLE, exiting it is a state
transition that must complete before anything else is sent. More
generally: polling every mailbox's `STATUS` in a tight loop is a way to
get rate-limited or disconnected. Gmail throttles IMAP aggressively.

### 2.6 Non-ASCII passwords

Nylas: IMAP authentication fails outright if the password contains
non-ASCII characters.

**CHECK:** `Owl.Keyring.MacOS` stores secrets as UTF-8 and
`Owl.Provider.IMAP.connectImap` passes them via `Text.unpack`. An
app-password is ASCII in practice, but a user-chosen password may not
be. Worth a deliberate decision rather than an accident.

---

## Class 3 — Parsing, encoding, threading. Affects code we have written

### 3.1 RFC 2047 encoded-words that break the rules

[#1189](https://github.com/neomutt/neomutt/issues/1189): headers from
Microsoft clients contain **spaces inside the encoded-word**, which the
RFC forbids. Strict parsing showed users raw `=?utf-8?B?...?=` gibberish.
NeoMutt had previously been lenient, got stricter, and regressed real
users.

**CHECK:** we delegate header decoding to `purebred-email`
(`MIME.defaultCharsets`, `IMF.headerSubject`). How lenient is it? Feed
it a malformed encoded-word and find out. If it is strict, our subjects
will show gibberish on mail from Outlook — a very common sender.

### 3.2 Escaped In-Reply-To breaks threading

[#2315](https://github.com/neomutt/neomutt/issues/2315): a remote
escaped the `In-Reply-To:` content; messages that belong together
appeared unrelated.

**CHECK:** `Owl.Message.Identity.parseRfcMessageId` and
`Owl.Message.Boundary.extractReferences`. We already *silently drop*
references that fail to parse (deliberately, so one bad header does not
reject a message) — which means broken threading fails **quietly**.
That is the right trade for ingestion and the wrong one for
diagnosis. Consider counting dropped references so it is at least
observable.

Also note NeoMutt shipped a manual repair function (`<link-threads>`,
bound to `&`) because senders break `References` often enough to
warrant a UI affordance. That is a strong signal about real-world
threading quality.

### 3.3 Messages with no declared charset

NeoMutt has an entire config variable for this — `$assumed_charset` —
described as *"a colon-separated list of character encoding schemes for
messages without character encoding indication"*, defaulting to
`us-ascii`. It exists because 8-bit bodies with no declared charset are
common.

**CHECK — likely a real gap.** `Owl.Message.Boundary.decodeCharset` is
currently a pass-through (`decodeCharset (RawMessage m) = Right
(DecodedMessage m)`) and `extractBody` relies on
`MIME.defaultCharsets`. What happens to a Latin-1 body with no charset
parameter? Probably mojibake or a dropped body. Worth a real test
fixture.

### 3.4 RFC 2231 parameter encoding (attachment filenames)

[#498](https://github.com/neomutt/neomutt/issues/498) records the
inverse pair of bugs: RFC 2047 decoding applied to MIME parameters
where it should not be, and RFC 2231 decoding *not* applied where it
should be. RFC 2231 is how non-ASCII filenames are encoded in
`Content-Disposition`.

**CHECK:** `Owl.Message.Boundary.extractAttachments` uses
`MIME.filename MIME.defaultCharsets`. Does purebred-email handle RFC
2231 continuations and charset-tagged parameters? Unverified. A
non-ASCII attachment filename is the test case.

### 3.5 MIME type coverage is a long tail

[#671](https://github.com/neomutt/neomutt/issues/671): `text/uri-list`
stopped rendering inline and became "unsupported", a regression that
annoyed a real user over a real workflow.

**CHECK:** `extractBody` looks only for `text/plain` and `text/html`.
Anything else — including `message/rfc822` forwarded mail, already on
our known-gaps list — yields no body at all.

---

## Class 4 — Probably immune; verify during live testing

[#407](https://github.com/neomutt/neomutt/issues/407): `EINTR`
("Interrupted system call") from `SIGWINCH` — an ordinary terminal
resize — made non-SSL IMAP unusable.

GHC's IO manager retries `EINTR` internally and vty owns `SIGWINCH`.
"Probably" is doing real work in that sentence. **Test:** resize the
terminal aggressively during an active sync.

---

## Not yet surveyed

Areas with years of accumulated NeoMutt experience we have not looked
at at all:

- SMTP send failures, partial sends, queueing
- Large-mailbox performance and header caching strategy
- Maildir/mbox local storage (less relevant — we use SQLite)
- GPG / S/MIME
- Attachment viewing and mailcap
- Config parsing, migration, and error reporting
- Address book / alias handling
- Sidebar, notmuch integration, virtual folders
- IDLE / push notification behaviour in depth

Each deserves its own pass.
