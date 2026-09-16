# Header privacy: what Owl can and cannot control

**Status: notes and requirements, not yet implemented.** Check each
"REQUIREMENT" against the codebase before assuming it holds.

---

## The dividing line

Outgoing mail headers come from two places:

1. **Headers Owl authors** — `Message-ID`, `Date`, `From`, `Subject`,
   `User-Agent`, etc. We have total control. Leaks here are our fault.
2. **Headers the provider's SMTP server authors** — chiefly the
   submission `Received:` line. Written *after* the message leaves our
   process, by a machine we do not control, and then covered by DKIM
   signing so it cannot be quietly removed downstream either.

Everything below follows from that split. **We can make Owl's own
contribution to the headers essentially anonymous. We cannot make mail
sent through a conventional provider anonymous.** Those are different
claims and we must never conflate them in anything user-facing.

---

## What we control — REQUIREMENTS

### R1. No hostname or username in `Message-ID`

The classic construction is `<timestamp.pid.hostname@domain>`, which
leaks the machine's hostname, often the username, sometimes the local
network name.

We are currently clean **by accident of design**: `MessageId` is a
random UUID and §13's `ValidatedRfcId` is generated, not derived from
the host. Make this a deliberate, documented, tested property so it
cannot be "optimised" away later by someone making IDs more readable.

**CHECK:** `Owl.Message.Identity`, and wherever outgoing `Message-ID`
is generated in the send path.

### R2. No `User-Agent` / `X-Mailer`

We do not currently emit one. That is a fingerprinting surface avoided
by omission — keep it that way, or make it explicitly opt-in. Note
that "which mail client, which version" is a meaningful narrowing of
who someone is.

**CHECK:** `Owl.Compose.renderDraft`, `Owl.Provider.SMTP.buildMail`.

### R3. `Date` in UTC, always

A `Date` header offset of `+0530` says India; `-0800` says the US west
coast. Per one 2026 audit, a UTC offset places you in a strip of the
world roughly 1,500 km wide. We build this header ourselves, so
emitting UTC is free.

Trade-off to accept knowingly: recipients lose the sender's local
time, which is occasionally useful context. Privacy wins here.

**CHECK:** wherever `sentAt` becomes a rendered `Date` header.

### R4. Attachment metadata is not ours to scrub — but say so

EXIF in images, author fields in documents. Out of scope for a mail
client to rewrite silently (mutating a user's file is worse), but
worth a future warning affordance rather than silence.

---

## What we do NOT control

### The submission `Received:` header

When Owl connects to the provider's SMTP server, that server records
the IP it saw — ours — and may write it into a `Received:` line. We
cannot strip it: it is added after our bytes leave, and it is
DKIM-covered.

**Whether it leaks depends entirely on the provider, not on us:**

| Provider behaviour | Examples (per 2026 sources) |
|---|---|
| Strips sender IP | Gmail / Workspace, Outlook.com, Yahoo, Proton, Tuta |
| Records sender IP | Office 365 corporate configs (as `x-eip`), self-hosted SMTP, many smaller/regional hosts, transactional senders |
| Disputed | Fastmail — sources conflict; **verify directly before claiming anything** |

A VPN or Tor changes *which* IP is recorded. It does not remove the
header. The provider sees your IP regardless; the only question is
whether they publish it.

### Related: `X-Originating-IP`

A de-facto standard header that webmail frontends add to record the
original client IP, because the frontend proxies to the mail server
and would otherwise mask it. Not something we emit; worth recognising
when reading headers.

---

## The Proton nuance that matters most to us

Proton hides the sender's IP for mail sent through **their web app**.
Proton's own documentation indicates the IP **may be visible when
sending via a desktop SMTP client** such as Thunderbird.

**Owl is exactly that kind of client.** So the privacy property people
associate with Proton is substantially a *webmail* property, and
submitting over SMTP from a desktop application can land in the
leaking case even on a privacy-focused provider.

Consequence: we cannot inherit a provider's privacy reputation. If we
ever surface privacy claims in the UI, they must be about Owl's own
headers, not about the delivery path.

---

## How we are permitted to describe this

- **Accurate:** "Owl adds no identifying metadata of its own — no
  hostname in the Message-ID, no client fingerprint, no local
  timezone." Most clients cannot say this.
- **NOT accurate, must never be said:** "Owl sends mail privately",
  "Owl hides your IP", "Owl makes email anonymous."

The honest summary: your mail provider is a witness by construction.
A client can refuse to add evidence; it cannot remove the provider's.

---

## Correction recorded for honesty

An earlier draft of this analysis asserted that Gmail's SMTP writes the
submitting client's IP into `Received:`. **That was wrong** — Gmail
strips it, and has for a long time. The underlying mechanism described
above is real; Gmail was simply a bad example of it. Recorded so the
error is not silently reintroduced from memory later.

---

## Open questions

- Fastmail's actual behaviour (sources conflict).
- Does `purebred-email`'s renderer inject any headers of its own?
  **CHECK `renderDraft` output byte-for-byte** — a library-added
  `User-Agent` would silently defeat R2.
- Does `mime-mail` (used by `Owl.Provider.SMTP.buildMail`) add
  anything? Same check, second renderer — we have two, and both must
  be clean.
