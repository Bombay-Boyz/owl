# Gold Standard for Email Client Engineering

**Document ID:** ECE-GOLD  
**Version:** 1.1  
**Status:** Normative Master Standard  
**Scope:** Engineering quality of modern email clients  
**Implementation-neutral:** Yes  
**Primary purpose:** Independent benchmark for architecture, specifications, source code, tests, releases, and audits

---

# 1. Purpose

This document defines a **gold-standard engineering benchmark for email clients**.

It is deliberately independent of:

- programming language
- user-interface technology
- operating system
- database technology
- protocol implementation strategy
- product branding
- feature count.

It is not an implementation specification.

It is not a protocol specification.

It is not a product roadmap.

It is a **normative engineering standard** against which an email client can be evaluated.

The standard answers:

> **What properties must a genuinely world-class email client possess, regardless of how those properties are implemented?**

The standard is intended to be used continuously throughout the project:

```text
Gold Standard
      ↓
Architecture
      ↓
Master Specification
      ↓
Detailed Specifications
      ↓
Source Code
      ↓
Tests
      ↓
Release
      ↓
Audit
```

The standard must remain independent of the implementation so that it cannot be weakened merely to accommodate implementation difficulties.

---

# 2. Normative Language

The following terms are normative.

### MUST

An absolute requirement.

Failure constitutes non-compliance.

### MUST NOT

An absolute prohibition.

Violation constitutes non-compliance.

### SHOULD

A strong recommendation.

Deviation requires a documented engineering justification.

### SHOULD NOT

A strong recommendation against a behavior.

Deviation requires justification.

### MAY

An optional capability.

Its absence is not itself a defect.

---

# 3. Conformance Philosophy

Conformance is not measured by feature count.

A client with fewer features may be superior to a feature-rich client if it provides substantially stronger:

- correctness
- reliability
- security
- synchronization
- recovery
- maintainability.

The fundamental rule is:

> **Implemented functionality MUST meet the applicable quality requirements of this standard. Unimplemented functionality does not create a requirement to implement it.**

This prevents feature breadth from becoming a substitute for engineering quality.

---

# 4. Quality Model

The standard evaluates eight primary dimensions:

```text
                 ┌───────────────┐
                 │  CORRECTNESS  │
                 └───────┬───────┘
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
       ▼                 ▼                 ▼
  RELIABILITY        SECURITY        SYNCHRONIZATION
       │                 │                 │
       └─────────────────┼─────────────────┘
                         │
              ┌──────────▼──────────┐
              │   ENGINEERING       │
              │      QUALITY        │
              └──────────┬──────────┘
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
       ▼                 ▼                 ▼
  PERFORMANCE       MAINTAINABILITY   VERIFICATION
```

Additional dimensions:

- usability
- accessibility
- internationalization
- observability
- operability
- privacy
- portability.

---

# 5. Conformance Levels

The standard defines five maturity levels.

## Level 0 — Unacceptable

The implementation contains fundamental defects such as:

- data-loss scenarios
- uncontrolled crashes
- serious security vulnerabilities
- undefined synchronization behavior
- unrecoverable state.

## Level 1 — Functional

The implemented feature works on the normal path.

This level is not production quality.

## Level 2 — Production

The implementation:

- handles normal failures
- persists important state
- has automated tests
- has defined security boundaries
- has operational diagnostics.

## Level 3 — Robust

The implementation additionally demonstrates:

- crash recovery
- offline behavior
- failure injection
- property testing
- fuzz testing
- deterministic state transitions
- bounded resources
- recoverable synchronization.

## Level 4 — World-Class

The implementation additionally demonstrates:

- explicit engineering invariants
- formalized state transitions
- convergence properties
- comprehensive failure matrices
- systematic compatibility testing
- measurable performance budgets
- strong security verification
- reproducible builds/tests
- traceability from requirement to implementation and verification.

## Level 5 — Gold Standard

The implementation:

1. satisfies all applicable mandatory requirements;
2. has no known unresolved critical or high-severity violation;
3. has explicit invariants for safety-critical state;
4. has automated verification for safety-critical invariants wherever technically feasible;
5. has defined behavior for all material failure classes;
6. demonstrates recovery from controlled failure;
7. demonstrates convergence under stated assumptions;
8. maintains complete requirement → specification → code → test traceability;
9. has independently reproducible verification;
10. does not weaken the standard to accommodate implementation limitations.

---

# 6. Requirement Classification

Every requirement belongs to one of four classes.

### M — Mandatory

Must be satisfied.

### S — Strong Recommendation

Should be satisfied unless a documented justification exists.

### O — Optional

Useful capability but not required.

### C — Conditional

Mandatory only when the relevant feature or architecture exists.

Example:

```text
C-SEC-HTML-001
If HTML email is rendered, the HTML security requirements apply.
```

This allows the standard to remain rigorous without forcing unnecessary features.

---

# 7. Requirement Identifiers

Every normative requirement receives a stable identifier.

Examples:

```text
COR-001
REL-001
SYNC-001
SEC-001
DATA-001
CON-001
PERF-001
TEST-001
OBS-001
OPS-001
PRIV-001
UX-001
A11Y-001
INTL-001
PORT-001
```

Requirement identifiers MUST NOT be reused for a different requirement.

---

# 8. Requirement Traceability

Every mandatory requirement implemented by the product SHOULD be traceable through:

```text
Requirement
    ↓
Design decision
    ↓
Specification
    ↓
Implementation
    ↓
Test
    ↓
Audit result
```

A mature project should maintain a traceability matrix:

| Requirement | Specification | Code | Verification | Status |
|---|---|---|---|---|
| COR-001 | §X | Module Y | Test Z | PASS |
| REL-004 | §X | Module Y | Test Z | PASS |
| SEC-003 | §X | Module Y | Fuzz Z | PASS |

---

# 9. Fundamental Engineering Principles

## PRINCIPLE-001 — User Data Is Sacred

The system MUST prioritize preservation of user data over convenience, performance, or feature behavior.

## PRINCIPLE-002 — Failure Is Normal

The architecture MUST assume:

- network failures
- server failures
- authentication failures
- process termination
- power failure
- malformed input
- concurrent modification.

## PRINCIPLE-003 — Untrusted Input Is Everywhere

Network-derived content MUST be treated as untrusted until appropriately parsed and validated.

## PRINCIPLE-004 — Local and Remote State Are Distinct

The client MUST NOT assume that local state and remote state are identical at all times.

## PRINCIPLE-005 — Ambiguity Must Be Represented

When the system cannot determine whether an operation succeeded, it MUST represent that uncertainty rather than inventing certainty.

## PRINCIPLE-006 — Derived Data Is Rebuildable

Caches, indexes and projections SHOULD be rebuildable from authoritative state.

## PRINCIPLE-007 — Correctness Precedes Optimization

Performance optimization MUST NOT weaken correctness or recoverability.

## PRINCIPLE-008 — Simplicity Is a Quality Property

The architecture SHOULD minimize unnecessary complexity while retaining required correctness.

---

# 10. Correctness

## COR-001 — Deterministic Domain Behavior

For identical:

- valid input
- state
- configuration
- capabilities

the domain decision MUST be deterministic unless nondeterminism is explicitly part of the requirement.

## COR-002 — Explicit State Transitions

Material state changes MUST have explicitly defined transitions.

## COR-003 — Invalid States

The implementation SHOULD make invalid domain states impossible or difficult to construct.

## COR-004 — No Silent Data Mutation

User data MUST NOT be silently altered without an explicit product rule.

## COR-005 — No Silent Data Loss

The client MUST NOT silently discard mail, drafts, contacts, operations or authoritative local state.

## COR-006 — Referential Integrity

References between domain objects MUST remain valid or fail in a controlled manner.

## COR-007 — Consistent Serialization

Serialization and deserialization of valid internal representations SHOULD preserve semantic meaning.

## COR-008 — Normalization

Normalization operations SHOULD be deterministic and idempotent where applicable.

---

# 11. Data Integrity

## DATA-001 — Authoritative State

The architecture MUST define which state is authoritative.

## DATA-002 — Derived State

Derived state MUST be identifiable as derived.

## DATA-003 — Rebuildability

Loss or corruption of derived state MUST NOT cause loss of authoritative data.

## DATA-004 — Atomicity

Related state changes that must be logically atomic MUST be persisted atomically.

## DATA-005 — Durability

Once the application represents an operation as durably committed, it MUST be recoverable after process failure.

## DATA-006 — Schema Integrity

Persistent schemas MUST be versioned.

## DATA-007 — Migration Safety

Schema migrations MUST NOT leave the database in a knowingly inconsistent state.

## DATA-008 — Corruption Detection

Material corruption SHOULD be detectable rather than silently propagated.

---

# 12. Reliability

## REL-001 — Crash Safety

The client MUST tolerate unexpected process termination without violating data-integrity invariants.

## REL-002 — Power Failure

Persistent operations MUST be designed so that an unexpected power loss does not create unrecoverable logical state.

## REL-003 — Recovery

The client MUST have a defined recovery procedure after abnormal termination.

## REL-004 — Retry Safety

Retryable operations MUST be explicitly classified.

## REL-005 — Bounded Retry

Retries MUST be bounded by policy and SHOULD use backoff.

## REL-006 — Unknown Outcome

Operations whose remote outcome cannot be determined MUST enter an explicit unknown state.

## REL-007 — No Blind Replay

Unknown operations MUST NOT be blindly replayed where replay could duplicate an irreversible action.

## REL-008 — Durable User Intent

Important user intent MUST be persisted before relying on asynchronous execution.

---

# 13. Distributed-State Engineering

This section is fundamental.

An email client is a distributed-state system.

The client interacts with:

- remote servers
- other email clients
- network intermediaries
- authentication systems.

Therefore remote state may change independently.

## DIST-001 — Independent Change

The architecture MUST assume remote state can change without the local client.

## DIST-002 — Partial Observability

The client MUST tolerate incomplete knowledge of remote state.

## DIST-003 — Reconciliation

The client MUST provide a mechanism for reconciling local and remote state.

## DIST-004 — Convergence

Subject to stated assumptions, if:

- communication eventually succeeds;
- the remote state eventually becomes stable;
- no new local operations occur;

the client SHOULD eventually converge on authoritative remote state.

## DIST-005 — Duplicate Events

Duplicate notifications or responses MUST NOT cause uncontrolled corruption.

## DIST-006 — Lost Notifications

Missing notifications MUST NOT permanently prevent synchronization.

## DIST-007 — Ordering

The implementation MUST NOT assume network events arrive in the same order in which they were generated unless the protocol explicitly guarantees it.

## DIST-008 — Conflict Policy

Material concurrent conflicts MUST have defined resolution semantics.

---

# 14. Synchronization

## SYNC-001 — Synchronization Is a First-Class Subsystem

Synchronization MUST NOT be scattered across UI or unrelated modules.

## SYNC-002 — Checkpoints

Synchronization checkpoints MUST be explicit.

## SYNC-003 — Checkpoint Safety

A checkpoint MUST NOT advance beyond state that has not been durably incorporated locally.

## SYNC-004 — Incremental Synchronization

Where the underlying protocol permits incremental synchronization, the client SHOULD use it.

## SYNC-005 — Full Resynchronization

The client MUST have a safe full-resynchronization path when incremental state becomes invalid.

## SYNC-006 — State Invalidation

The implementation MUST detect conditions under which cached synchronization state is no longer valid.

## SYNC-007 — Recovery

Synchronization MUST be restartable after interruption.

## SYNC-008 — Reconciliation

Synchronization MUST reconcile rather than merely replay a sequence of assumed operations.

---

# 15. Identity

## ID-001 — Distinct Identity Domains

Different protocol and application identifiers MUST NOT be conflated.

## ID-002 — Stable Local Identity

Local identity MUST remain stable according to the application's defined lifetime.

## ID-003 — Protocol Identity

Protocol-specific identity MUST retain all information required for correctness.

## ID-004 — Identity Invalidation

When protocol semantics invalidate an identity mapping, stale mappings MUST NOT silently continue to be used.

---

# 16. Conflict Resolution

## CON-001 — Defined Conflict Semantics

Every material concurrent mutation class MUST have defined semantics.

## CON-002 — No Accidental Last-Writer-Wins

Last-writer-wins MUST NOT be used merely because it happens to emerge from execution order.

## CON-003 — Safe Merge

Where operations can be safely merged, the system SHOULD prefer deterministic merging.

## CON-004 — Irreversible Conflict

Irreversible conflicts MUST be handled conservatively.

## CON-005 — User Visibility

Where automatic resolution cannot safely determine the intended result, the client SHOULD expose the relevant condition to the user.

---

# 17. Idempotency

## IDEM-001

Operations SHOULD be designed around setting desired state rather than toggling state when protocol semantics permit.

## IDEM-002

Retrying an idempotent operation MUST NOT create additional unintended effects.

## IDEM-003

Recovery procedures SHOULD themselves be idempotent.

---

# 18. Security

## SEC-001 — Threat Model

The project MUST maintain an explicit threat model.

## SEC-002 — Trust Boundaries

Security-sensitive trust boundaries MUST be documented.

## SEC-003 — Network Input

Network input MUST be treated as untrusted.

## SEC-004 — Message Content

Message content MUST be treated as untrusted.

## SEC-005 — Authentication

Authentication credentials and tokens MUST be protected.

## SEC-006 — Transport Security

Mail transport MUST use appropriate authenticated encryption.

## SEC-007 — No Silent Downgrade

Security failures MUST NOT silently downgrade to insecure transport.

## SEC-008 — Secret Logging

Credentials, tokens and sensitive message content MUST NOT be written to ordinary logs.

## SEC-009 — Least Privilege

Components SHOULD operate with the minimum privileges required.

## SEC-010 — Secure Defaults

Security-sensitive functionality MUST default to the safer behavior.

---

# 19. Untrusted Content

## SEC-CONTENT-001

Malformed message content MUST NOT crash the client.

## SEC-CONTENT-002

HTML content MUST NOT execute with application privileges.

## SEC-CONTENT-003

Active content MUST be explicitly controlled.

## SEC-CONTENT-004

External resources MUST be governed by an explicit policy.

## SEC-CONTENT-005

URLs MUST be parsed and handled according to a security policy.

## SEC-CONTENT-006

Attachment filenames MUST NOT be trusted as filesystem paths.

## SEC-CONTENT-007

Resource-intensive content MUST be bounded.

---

# 20. MIME and Parsing

## PARSE-001

Parsers MUST distinguish malformed input from valid input.

## PARSE-002

Malformed input MUST produce a controlled result.

## PARSE-003

Parsing MUST enforce resource limits.

## PARSE-004

Recursive structures MUST have bounded depth.

## PARSE-005

Decoded expansion MUST be bounded.

## PARSE-006

Security-critical parsers SHOULD be fuzz-tested.

---

# 21. Internationalization and Encoding

## INTL-001 — Charset Correctness

Message and header text MUST be decoded using its declared or correctly detected charset before domain use.

## INTL-002 — Encoding Fallback

If a declared charset is missing or invalid, the client MUST apply a defined, deterministic fallback rather than guessing silently and inconsistently.

## INTL-003 — Address Internationalization

Internationalized email addresses and domain names MUST be handled according to the applicable standard; they MUST NOT be silently truncated or mangled.

## INTL-004 — Bidirectional and Mixed-Script Text

Display of bidirectional and mixed-script text MUST NOT alter the semantic meaning of addresses, links, or filenames.

## INTL-005 — Locale-Sensitive Formatting

Dates, times, and numbers SHOULD be formatted per the user's locale without altering the underlying stored value.

## INTL-006 — Encoding Round-Trip

Re-encoding previously decoded text for transmission or storage MUST preserve meaning; lossy re-encoding MUST be explicit, not silent.

---

# 22. Resource Security

## RES-001

Externally controlled resource consumption MUST be bounded.

Limits SHOULD exist for:

- message size
- MIME depth
- MIME parts
- attachment size
- HTML size
- decoded size
- concurrent operations
- search result size
- retries
- cache size.

## RES-002

The system MUST fail safely when limits are exceeded.

## RES-003

Resource exhaustion MUST NOT corrupt authoritative state.

---

# 23. Privacy

## PRIV-001

The client SHOULD minimize unnecessary external network requests.

## PRIV-002

Tracking resources SHOULD NOT be fetched by default without an explicit policy permitting them.

## PRIV-003

Telemetry MUST be privacy-preserving and explicitly governed.

## PRIV-004

Sensitive local data SHOULD use appropriate operating-system security facilities.

---

# 24. Authentication and Credentials

## AUTH-001

Authentication MUST be isolated from ordinary mail-domain logic.

## AUTH-002

Credentials MUST NOT be stored in plaintext unless explicitly required by the environment and protected accordingly.

## AUTH-003

Tokens MUST NOT appear in logs.

## AUTH-004

Authentication failure MUST be distinguishable from transient network failure.

## AUTH-005

Expired credentials MUST NOT cause infinite retry loops.

---

# 25. Protocol Independence

## PROTO-001

The domain model MUST NOT depend directly on a specific mail protocol.

## PROTO-002

Protocol adapters MUST translate between wire representations and domain representations.

## PROTO-003

Provider-specific behavior MUST be isolated from general domain logic.

## PROTO-004

Capabilities SHOULD be discovered rather than inferred from provider names.

## PROTO-005

Protocol limitations MUST be represented explicitly.

---

# 26. Portability

## PORT-001 — Platform Isolation

Platform-specific and OS-specific code MUST be isolated behind defined interfaces, not scattered through domain logic.

## PORT-002 — Storage Portability

Local data formats SHOULD NOT assume a single storage engine is permanently irreplaceable.

## PORT-003 — Path and Filesystem Assumptions

The implementation MUST NOT assume filesystem semantics (case sensitivity, path length, reserved characters) that do not hold across supported platforms.

## PORT-004 — No Undocumented Platform Coupling

Behavior MUST NOT silently depend on undocumented platform quirks that a compliant alternative platform is not obligated to replicate.

---

# 27. Concurrency

## CONCUR-001

Shared mutable state MUST have explicit ownership.

## CONCUR-002

Concurrent operations MUST have defined interaction semantics.

## CONCUR-003

The system MUST bound concurrent work.

## CONCUR-004

Cancellation MUST be handled safely.

## CONCUR-005

Cancellation MUST NOT silently violate persistence invariants.

## CONCUR-006

Background tasks MUST have defined lifecycle ownership.

---

# 28. Performance

Performance is a quality attribute, not merely an optimization exercise.

## PERF-001

Common UI actions SHOULD remain responsive independently of network latency where safe.

## PERF-002

The client SHOULD use local state for operations that do not require immediate server confirmation.

## PERF-003

Large data SHOULD be streamed or incrementally processed.

## PERF-004

Search SHOULD use an appropriate local index for local data.

## PERF-005

Concurrency MUST NOT be increased without resource controls.

## PERF-006

Performance targets SHOULD be measurable.

Examples:

```text
cold startup
warm startup
mailbox opening
message opening
search
autocomplete
incremental synchronization
attachment streaming
```

---

# 29. Performance Budgets

A production project SHOULD define explicit budgets.

Example categories:

```text
Startup latency
Mailbox navigation latency
Search latency
Autocomplete latency
Memory ceiling
Concurrent connection ceiling
Cache disk ceiling
Synchronization throughput
```

The exact numbers are product-specific.

The requirement is that they be:

- defined
- measured
- regression-tested.

---

# 30. Maintainability

## MAINT-001

Modules MUST have clear responsibilities.

## MAINT-002

Dependencies MUST have clear direction.

## MAINT-003

Security-critical behavior MUST NOT be duplicated unnecessarily.

## MAINT-004

Provider-specific behavior MUST NOT leak through the architecture.

## MAINT-005

Complex algorithms SHOULD have explicit invariants and documentation.

## MAINT-006

Dead code and obsolete abstractions SHOULD be removed.

---

# 31. Simplicity

## SIMPLE-001

Complexity MUST have a documented reason.

## SIMPLE-002

The architecture SHOULD prefer a smaller number of strong abstractions over many weak abstractions.

## SIMPLE-003

Abstraction SHOULD follow actual domain boundaries rather than speculative future requirements.

## SIMPLE-004

The system MUST NOT introduce distributed complexity merely to solve a local problem.

---

# 32. Testability

## TEST-001

Critical domain logic MUST be independently testable.

## TEST-002

Synchronization decisions SHOULD be testable without requiring a live network.

## TEST-003

Security-critical parsers SHOULD be independently fuzzable.

## TEST-004

Recovery behavior MUST be testable.

## TEST-005

Persistence invariants MUST be testable.

---

# 33. Testing Layers

A gold-standard project should employ:

```text
Unit Tests
    ↓
Property Tests
    ↓
Integration Tests
    ↓
Protocol Tests
    ↓
Fuzz Tests
    ↓
Failure Injection
    ↓
Crash Recovery
    ↓
Compatibility Testing
    ↓
Performance Regression Testing
```

No single testing technique is sufficient.

---

# 34. Property Testing

Safety-critical properties SHOULD be expressed as executable properties where feasible.

Examples:

```text
Normalization(normalization(x)) = normalization(x)
```

```text
Recovery(recovery(state)) = recovery(state)
```

```text
Rebuilding(search index) produces equivalent search results
```

```text
IdempotentOperation(IdempotentOperation(state))
    = IdempotentOperation(state)
```

```text
Threading(state) = Threading(state)
```

---

# 35. Fuzz Testing

Fuzz testing SHOULD target all externally controlled parsers.

Minimum targets where applicable:

- message parser
- MIME parser
- header parser
- address parser
- date parser
- protocol parser
- HTML sanitizer
- URL parser
- search query parser.

Required property:

> Arbitrary input produces either a valid result or a controlled error, never an uncontrolled process failure.

---

# 36. Failure Injection

The project MUST test material failure classes.

Examples:

```text
DNS failure
TCP reset
TLS failure
authentication failure
timeout
server disconnect
malformed server response
lost response
duplicate response
duplicate notification
missing notification
process termination
database failure
disk-full condition
```

---

# 37. Crash Testing

The system SHOULD deliberately terminate the process at critical points:

```text
before transaction
during transaction
after transaction
before operation submission
during operation submission
after remote execution
before checkpoint
after checkpoint
```

After restart, all applicable invariants MUST remain true.

---

# 38. Observability

## OBS-001

Material operations MUST be diagnosable.

## OBS-002

Logs SHOULD be structured.

## OBS-003

Logs MUST protect sensitive information.

## OBS-004

Synchronization diagnostics SHOULD expose:

- current state
- last successful synchronization
- pending operations
- checkpoint state
- connection status
- failures
- retry state.

---

# 39. Operational Diagnostics

A diagnostic report should be capable of expressing something similar to:

```text
Account: Work
Protocol: IMAP

Mailbox: INBOX

Synchronization:
    state: synchronized
    last_success: 10:42:31
    checkpoint: X
    pending_operations: 1

Messages:
    known: 8421
    new: 4
    changed: 13
    vanished: 2

Connection:
    encrypted: yes
    authenticated: yes
```

Diagnostics MUST NOT expose secrets.

---

# 40. Usability

Usability requirements apply to implemented functionality.

## UX-001

Common actions MUST be discoverable.

## UX-002

Destructive operations MUST have predictable semantics.

## UX-003

Errors MUST communicate what happened and what the user can do.

## UX-004

The interface SHOULD remain usable during network degradation.

## UX-005

The interface SHOULD distinguish:

```text
saved locally
queued
synchronizing
synchronized
failed
unknown
```

where that distinction is meaningful.

---

# 41. Accessibility

## A11Y-001 — Assistive Technology Compatibility

Implemented interface functionality MUST be operable through the platform's standard assistive technology interfaces.

## A11Y-002 — Keyboard Operability

Common actions MUST be operable without requiring pointer input.

## A11Y-003 — Non-Color-Dependent State

Status distinguished in UX-005 MUST NOT be conveyed by color alone.

## A11Y-004 — Text Scaling

Interface text MUST remain legible and functional under platform-level text-size scaling.

## A11Y-005 — Motion and Animation Control

Non-essential motion SHOULD respect the platform's reduced-motion preference.

---

# 42. Error Handling

Errors MUST be structured sufficiently to support:

- classification
- recovery
- logging
- user communication.

Errors SHOULD distinguish:

```text
Transient
Permanent
Unknown outcome
Security failure
Data integrity failure
Configuration failure
```

---

# 43. Error Message Quality

A user-facing error SHOULD answer:

1. What happened?
2. Is user data safe?
3. What can the user do?
4. Will the client retry automatically?
5. Does the user need to intervene?

Technical protocol details may be available in diagnostics but should not be the only explanation.

---

# 44. Configuration

## OPS-001

Configuration MUST be validated before use.

## OPS-002

Configuration SHOULD have typed representations.

## OPS-003

Invalid configuration MUST fail predictably.

## OPS-004

The normal setup path SHOULD require minimal protocol knowledge.

## OPS-005

Advanced configuration MAY expose low-level controls.

---

# 45. Database and Migration Standards

## DB-001

Database schema MUST be versioned.

## DB-002

Migrations MUST be tested.

## DB-003

Migration failure MUST be detectable.

## DB-004

Migration execution MUST NOT knowingly leave a partially applied logical schema.

## DB-005

Database corruption SHOULD be detectable.

## DB-006

The system SHOULD provide safe rebuild procedures for derived structures.

---

# 46. Dependency Management

## DEP-001

Dependencies MUST have an identified purpose.

## DEP-002

Security-sensitive dependencies SHOULD be actively maintained.

## DEP-003

Dependencies SHOULD be minimized where reasonable.

## DEP-004

The project MUST NOT reimplement security-critical functionality merely to reduce dependency count.

## DEP-005

Dependency upgrades MUST be tested against the project's quality gates.

---

# 47. Build Reproducibility

## BUILD-001

Production builds SHOULD be reproducible.

## BUILD-002

Build dependencies SHOULD be version-pinned appropriately.

## BUILD-003

Release artifacts SHOULD be traceable to source revisions.

## BUILD-004

The exact toolchain used for a release SHOULD be recorded.

---

# 48. Release Engineering

A release MUST have:

- identified source revision
- dependency state
- schema version
- test results
- known limitations
- security status
- migration status.

A release SHOULD have:

- reproducible build information
- performance regression results
- compatibility results.

---

# 49. Security-Critical Components

The following components require elevated scrutiny where applicable:

```text
Authentication
TLS
MIME parsing
HTML sanitization
URL handling
Attachment handling
Filesystem interaction
Credential storage
Protocol parsing
```

These SHOULD receive:

- focused review
- fuzz testing
- explicit invariants
- conservative design
- regression tests.

---

# 50. Engineering Invariants

The following invariants form part of the gold standard.

## INV-DATA-001

No committed user-visible operation may be lost solely because of process termination.

## INV-DATA-002

Derived data may be destroyed and rebuilt without loss of authoritative state.

## INV-SYNC-001

Synchronization checkpoints never advance ahead of durably incorporated remote state.

## INV-SYNC-002

Unknown remote operation outcomes remain explicitly unknown until reconciled.

## INV-SYNC-003

When the stated convergence assumptions hold, local state eventually converges to authoritative remote state.

## INV-ID-001

A protocol identifier is never interpreted outside the identity context required by that protocol.

## INV-SEC-001

Untrusted content cannot directly execute with application privileges.

## INV-SEC-002

Untrusted resource requests are governed by policy and resource limits.

## INV-RES-001

External input cannot cause unbounded resource consumption.

## INV-SEARCH-001

Search indexes are derived state and cannot be the sole authoritative representation of mail.

## INV-DRAFT-001

A send failure cannot destroy the originating draft.

## INV-ARCH-001

The domain model remains independent of transport-specific representation.

## INV-REC-001

Recovery procedures are safe to execute repeatedly where applicable.

---

# 51. Failure Matrix

The project MUST maintain a failure matrix covering at least:

| Failure | Required response |
|---|---|
| DNS failure | Preserve local usability; retry according to policy |
| TLS failure | Do not downgrade |
| Authentication failure | Stop inappropriate retries; request intervention |
| Temporary server error | Bounded retry |
| Permanent server error | Surface actionable error |
| Timeout | Classify appropriately |
| Connection lost after mutation | Unknown outcome + reconciliation |
| Process killed during transaction | Recover atomically |
| Process killed during synchronization | Resume/reconcile |
| Synchronization checkpoint invalid | Reconstruct safely |
| Remote identity invalidated | Rebuild affected mapping |
| Remote message disappears | Reconcile |
| Concurrent mutation | Apply defined conflict policy |
| Duplicate event | Safe/no uncontrolled mutation |
| Missing event | Periodic/explicit reconciliation |
| Malformed message | Controlled handling |
| Malicious HTML | Sanitize/restrict |
| Oversized attachment | Bound/stream/reject safely |
| Search index corruption | Rebuild |
| Database failure | Preserve consistency and surface failure |
| Disk full | Avoid silent corruption |
| Credential expiry | Re-authenticate or surface intervention |
| Cancellation | Preserve state invariants |

---

# 52. Convergence Standard

A synchronization implementation should be able to state its convergence assumptions explicitly.

Example:

```text
If:

1. the server remains reachable eventually;
2. authentication eventually succeeds;
3. the server eventually becomes stable;
4. no new local operations are introduced;

then:

the client eventually reaches a synchronized state
equivalent to the authoritative remote state.
```

This statement SHOULD be tested through simulation.

---

# 53. Security Verification Matrix

Every major threat should map to controls and tests.

| Threat | Control | Verification |
|---|---|---|
| Malicious HTML | Sanitization | Security tests + fuzzing |
| Malformed MIME | Defensive parser | Fuzzing |
| Credential leakage | Secret isolation | Static/review tests |
| TLS downgrade | Strict transport policy | Integration tests |
| Path traversal | Filename validation | Security tests |
| Resource exhaustion | Limits | Stress/fuzz tests |
| Malicious URL | URL policy | URL corpus tests |
| Tracking | Remote-resource policy | Rendering tests |

---

# 54. Audit Methodology

Audits MUST evaluate:

1. Requirement compliance
2. Architecture compliance
3. Implementation compliance
4. Test coverage
5. Failure behavior
6. Security controls
7. Invariant preservation
8. Operational diagnostics.

An auditor MUST NOT declare compliance solely because:

- the code compiles
- tests pass
- the feature works manually.

---

# 55. Audit Evidence

Acceptable evidence includes:

- source code
- architecture documents
- design records
- automated tests
- fuzzing results
- benchmarks
- failure-injection results
- compatibility matrices
- migration tests
- security assessments
- reproducible build results.

Claims without evidence SHOULD be treated as unverified.

---

# 56. Audit Status

Every requirement should receive one of:

```text
PASS
PARTIAL
FAIL
NOT APPLICABLE
UNVERIFIED
```

Definitions:

### PASS

Evidence demonstrates compliance.

### PARTIAL

Some but not all requirements are satisfied.

### FAIL

The requirement is violated.

### NOT APPLICABLE

The requirement does not apply to the implemented product.

### UNVERIFIED

The implementation may satisfy it, but sufficient evidence does not exist.

---

# 57. Severity

Defects should be classified:

## Critical

Potential:

- irreversible data loss
- credential compromise
- remote code execution
- catastrophic corruption.

## High

Material:

- synchronization corruption
- significant security failure
- repeated data loss
- unrecoverable operations.

## Medium

Material reliability/usability degradation without catastrophic consequences.

## Low

Limited impact or quality issue.

## Informational

No material compliance impact.

A Gold release MUST have:

```text
Critical = 0
High = 0
```

unless a formally approved exception exists.

---

# 58. Exceptions

Exceptions MUST be explicit.

An exception should contain:

```text
Requirement ID
Reason
Risk
Affected components
Compensating controls
Owner
Approval
Review date
```

An exception MUST NOT silently redefine the requirement.

---

# 59. Technical Debt

Known technical debt MUST be recorded.

Technical debt that violates a mandatory requirement is not merely "technical debt".

It is:

> **non-compliance.**

This distinction prevents serious engineering defects from being hidden under a generic backlog label.

---

# 60. Definition of Done

A feature is not "done" merely because it works.

A feature is done when:

```text
Requirement defined
      ↓
Design reviewed
      ↓
Implementation complete
      ↓
Failure behavior defined
      ↓
Security considered
      ↓
Tests implemented
      ↓
Observability implemented
      ↓
Documentation updated
      ↓
Audit passes
```

---

# 61. Definition of Production Ready

A subsystem is production-ready only when:

- normal behavior works
- failure behavior is defined
- recovery behavior is tested
- security boundary is reviewed
- resources are bounded
- important invariants are tested
- observability exists
- no known critical defect remains.

---

# 62. Definition of World-Class

A system is world-class when it is not merely functional but demonstrates disciplined control over:

```text
State
Failure
Security
Concurrency
Resources
Protocols
Recovery
Verification
Change
```

The defining characteristic is not sophistication.

It is **predictability under adverse conditions**.

---

# 63. Definition of Gold Standard

A system reaches Gold Standard conformance when:

```text
                    GOLD
                     │
      ┌──────────────┼──────────────┐
      │              │              │
 Correctness     Reliability     Security
      │              │              │
      └──────────────┼──────────────┘
                     │
              Synchronization
                     │
              ┌──────▼──────┐
              │ Invariants  │
              └──────┬──────┘
                     │
              Verification
                     │
              ┌──────▼──────┐
              │   Audit     │
              └─────────────┘
```

All mandatory requirements pass.

Critical and high-severity violations are absent or formally excepted.

Safety-critical invariants have automated verification wherever technically feasible.

Material failure modes have defined behavior.

Recovery has been demonstrated, not merely documented.

The implementation is traceable to the standard.

The test suite is capable of detecting regression against the standard.

---

# 64. Master Audit Checklist

Before a release can claim Gold Standard conformance:

## Correctness

- [ ] Domain invariants defined
- [ ] State transitions defined
- [ ] Identity semantics defined
- [ ] Invalid states controlled
- [ ] No known silent data loss
- [ ] Deterministic behavior verified

## Reliability

- [ ] Crash recovery tested
- [ ] Power-loss behavior considered
- [ ] Durable operations verified
- [ ] Retry policy defined
- [ ] Unknown outcomes handled
- [ ] Recovery is repeatable

## Synchronization

- [ ] Synchronization state explicit
- [ ] Checkpoints explicit
- [ ] Checkpoint safety verified
- [ ] Incremental synchronization verified where applicable
- [ ] Full recovery path exists
- [ ] Conflict semantics defined
- [ ] Convergence assumptions defined
- [ ] Convergence tested

## Security

- [ ] Threat model exists
- [ ] Trust boundaries documented
- [ ] Transport security verified
- [ ] Authentication secure
- [ ] Secrets excluded from logs
- [ ] Untrusted content isolated
- [ ] HTML policy verified
- [ ] URL handling verified
- [ ] Attachment handling verified
- [ ] Resource limits tested

## Data

- [ ] Authoritative state identified
- [ ] Derived state identified
- [ ] Derived state rebuild tested
- [ ] Transactions tested
- [ ] Schema versioned
- [ ] Migrations tested
- [ ] Corruption handling defined

## Internationalization

- [ ] Charset decoding verified
- [ ] Encoding fallback defined
- [ ] Internationalized addresses tested
- [ ] Bidirectional text display verified against spoofing

## Concurrency

- [ ] Ownership defined
- [ ] Cancellation safe
- [ ] Background workers bounded
- [ ] Concurrent mutations defined
- [ ] Race-sensitive behavior tested

## Performance

- [ ] Performance budgets defined
- [ ] Benchmarks exist
- [ ] Regression thresholds defined
- [ ] Memory bounded
- [ ] Network behavior measured

## Verification

- [ ] Unit tests
- [ ] Property tests
- [ ] Fuzz tests
- [ ] Integration tests
- [ ] Protocol tests
- [ ] Failure injection
- [ ] Crash recovery tests
- [ ] Compatibility tests
- [ ] Security tests

## Operations

- [ ] Structured logging
- [ ] Synchronization diagnostics
- [ ] Error classification
- [ ] Configuration validation
- [ ] Release metadata
- [ ] Reproducible build information

## Accessibility

- [ ] Assistive technology compatibility verified
- [ ] Keyboard operability verified
- [ ] Status conveyed without reliance on color alone

## Portability

- [ ] Platform-specific code isolated
- [ ] Undocumented platform dependencies identified and removed

## Audit

- [ ] Requirement IDs complete
- [ ] Traceability matrix complete
- [ ] All mandatory requirements assessed
- [ ] All critical defects resolved
- [ ] All high defects resolved
- [ ] Exceptions documented
- [ ] Final certification recorded

---

# 65. Certification Statement

A project claiming compliance SHOULD publish a statement similar to:

```text
This release has been evaluated against ECE-GOLD.

Applicable mandatory requirements:
    PASS: N
    PARTIAL: 0
    FAIL: 0
    UNVERIFIED: 0

Critical findings:
    0

High findings:
    0

Known exceptions:
    N

Verification includes:
    Unit testing
    Property testing
    Fuzz testing
    Integration testing
    Failure injection
    Crash recovery
    Security testing
    Performance testing

Release:
    <version>

Source revision:
    <revision>

Audit date:
    <date>
```

---

# 66. The Standard's Central Principle

Everything in this document ultimately reduces to one requirement:

> **The client must remain correct when reality is inconvenient.**

Reality includes:

- broken networks
- slow networks
- disappearing networks
- unreliable servers
- concurrent clients
- malformed messages
- hostile content
- expired credentials
- process crashes
- power failures
- corrupted derived state
- unexpected protocol behavior
- incomplete information.

A world-class client is one that remains predictable under those conditions.

---

# 67. Final Engineering Constitution

The following principles are considered constitutional.

1. **Never lose user data.**
2. **Never silently corrupt state.**
3. **Never confuse identity domains.**
4. **Never treat uncertainty as certainty.**
5. **Never advance synchronization state prematurely.**
6. **Never trust external content.**
7. **Never allow uncontrolled resource consumption.**
8. **Never silently downgrade security.**
9. **Never let provider quirks contaminate the domain model.**
10. **Never rely on derived state as the source of truth.**
11. **Never allow a crash to destroy committed user intent.**
12. **Never make retry behavior accidental.**
13. **Never make concurrency ownership ambiguous.**
14. **Never declare functionality production-ready without failure verification.**
15. **Never change the standard merely to make the implementation conform.**

---

# 68. Final Definition

> **ECE-GOLD defines a world-class email client as a system whose behavior remains correct, secure, recoverable, deterministic and explainable across normal operation, failure, concurrency, synchronization uncertainty, hostile input and environmental change; whose critical properties are expressed as explicit invariants; and whose compliance can be demonstrated through objective evidence rather than assertion.**

This document is the **yardstick**.

Architecture documents, implementation specifications, source code, tests, releases and audits are measured against it.

The implementation does not define the standard.

**The standard defines what the implementation must achieve.**
