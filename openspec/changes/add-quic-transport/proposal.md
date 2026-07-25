# Proposal: add-quic-transport

## Why

The pluggable-transport milestone (RandomPlayer #344/#345, AMSMB2 #28) landed the `SMBTransport` seam and flipped Apple platforms onto it, but `SMBTransportKind.quic` is still a reserved case that throws `ENOTSUP` (`Context.swift:1128`). SMB-over-QUIC (UDP/443, TLS 1.3) is the core feature of the current milestone (AMSMB2 #29, RandomPlayer #346): it lets the client reach Windows Server 2025 / Samba 4.23+ file servers over untrusted networks where TCP/445 is blocked, and it unblocks RandomPlayer #347.

## What Changes

- Add `QUICTransportApple`, a new `SMBTransport` conformer backed by Network.framework QUIC (`NWProtocolQUIC`) — system QUIC, nothing to ship, App-Store-safe. Availability-gated (`@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)`; Package.swift's floors — including `.macCatalyst(.v13)` — are unchanged); older OS versions fail with `ENOTSUP`. Its `connect` is a self-contained, deadline-bounded, cancellable state machine over `NWConnection` in which outcome *selection* and cleanup-*duty assignment* are a single atomic, lock-protected transition, while the assigned effects (cancelling the deadline timer, cancelling the connection, resuming the continuation) are performed outside the lock by the party the transition named — which, for a loss landing in the commit-to-start window, is the starting path rather than the winner, with every `close()` call waiting for that parked teardown to complete before returning — so a returned `close()` guarantees no parked driver start or cancel remains outstanding (design D7) — it cannot rely on libsmb2's timeout machinery, which is not yet installed during the eager transport connect; the deadline comes from a dedicated `SMBQUICConfiguration.connectTimeout` (default 30 s, design D10), independent of `SMB2Manager.timeout`'s "zero/negative disables" contract. On the client side, `SMB2Client.connectWithBridge` guards the entire interval from before the eager `bridge.connect` through seam installation with a lock-protected bridge-ownership handoff (design D12): exactly one owner is responsible for closing the bridge at every point — the eager-completion reconciliation after `bridge.connect` returns (which closes the still-local bridge exactly once on every cancellation or failure outcome and normalizes a cancellation win to `CancellationError`, regardless of the conformer's internal cancellation error — `TCPTransportApple` maps cancellation to `POSIXError(.ECANCELED)`, the QUIC machine throws `CancellationError`), the cancellation handler while the bridge is locally owned, or the installed seam's `teardownSeam()` — and `smb2_set_transport`/`smb2_connect_share_async` never begin once cancellation has won.
- Wire mapping follows the Microsoft/Samba interop behavior (verified against Samba's client implementation, `source3/libsmb/smbsock_connect.c`): ALPN token `"smb"`, TLS 1.3, one QUIC connection with a **single bidirectional stream used as a byte pipe**. The stream carries the exact same framed SMB2 byte stream as direct TCP (4-byte transport length prefix included) — libsmb2 keeps doing all SMB framing/auth inside the tunnel; the transport stays a dumb pipe, same as `TCPTransportApple`.
- Connection policy (per #346 — "don't get these wrong"):
  - QUIC is **explicit opt-in** — never auto-selected; `.automatic` continues to mean TCP.
  - **Numeric hosts rejected** — any host the platform resolver classifies as a numeric IPv4/IPv6 address *without DNS* (`getaddrinfo` with `AI_NUMERICHOST`) is refused, including legacy forms such as `127.1`, `2130706433`, hex/octal IPv4, and scoped IPv6 (`fe80::1%en0`) — not just canonical `inet_pton` literals (mirrors Samba/Windows client behavior). The required rejection table is acceptance criteria: if the platform classifier misses a listed form, the classifier is supplemented with deterministic parsing — the table is never weakened (design D4). Rejection runs before the TLS trust policy is applied and is independent of it; `.insecureNoVerification` never bypasses it (with chain and hostname verification disabled, no later validation layer would catch a numeric target).
  - Default port **UDP/443** when the server string has no explicit port (TCP keeps 445). Explicit ports are validated to `1...65535` at endpoint validation, before any transport is constructed; endpoint parsing is overflow-safe, so an oversized digit string of any length yields `EINVAL` instead of trapping (design D4).
  - No silent TCP fallback: a QUIC connect failure surfaces as an error; falling back is the caller's decision.
- TLS security surface: system trust evaluation and hostname verification by default — **never insecure by default**. Trust is a mutually exclusive policy (`system` / `customRoots` / `insecureNoVerification`, design D5): custom DER trust anchors (covering private-CA and self-signed server certificates) *replace* system roots and keep hostname verification; the insecure escape hatch is a separate, explicit case. Certificate/SPKI *pinning* is explicitly **not** part of this change.
- Public API: `SMB2Manager` gains transport selection (today `connect(shareName:encrypted:)` hardcodes `.automatic`, `AMSMB2.swift:1511`) plus `SMBQUICConfiguration`, a platform-neutral options type (trust anchors as DER `[Data]`, converted to `SecCertificate` only inside the Apple transport — so the type compiles and exists on Linux; plus the `connectTimeout` knob, design D10). The manager snapshots both settings under its `connectLock` before suspending; on Apple the immutable snapshot flows through `SMB2Client.connect(server:share:user:transportKind:quicConfiguration:)` (a `#if canImport(Network)` signature) into the transport initializer (design D6), where `.quic` constructs `QUICTransportApple` instead of throwing; on Linux the manager routes on the same snapshot (`.quic` → `ENOTSUP` before any network activity, `.tcp`/`.automatic` → the legacy path unchanged). Copying (`NSCopying`) preserves both settings. The new surface is intentionally Swift-only — not Objective-C-representable and not exposed to ObjC; the existing ObjC API is unchanged (design D11).
- Disconnect semantics are unchanged (option B, design D8): `TransportBridge` is untouched; the SMB DISCONNECT PDU remains best-effort local (queued and flushed into the bridge, but teardown may cancel the outbound pump before wire delivery). "Graceful disconnect" is **not** claimed as a guaranteed interop result; the transport distinguishes peer-originated graceful EOF, local close, and abnormal loss through an explicit recorded-cause lifecycle (design D8): local `close()` records its cause before cancelling the `NWConnection`, so the resulting `.cancelled` event is never misread as abnormal transport loss, while an unsolicited post-ready `.failed` or `.cancelled` remains abnormal loss.
- Tests: unit tests for policy (table-driven numeric-host rejection, port defaulting, opt-in dispatch, availability gating, connect-timeout boundary cases), configuration plumbing/snapshot semantics, `NSCopying`/`NSSecureCoding`/`Codable` of the new settings, the connect state machine — driven deterministically through injected connection-driver and deadline-scheduler seams (cancellation, deadline, completion races, and connection-ownership/side-effect assertions; no wall-clock or TEST-NET dependence, design D7) — the D12 bridge-ownership handoff (transition-table unit tests covering every eager-completion reconciliation outcome and race order, plus MockTransport-backed coverage: exactly-once close in every outcome, internal-`ECANCELED`-to-`CancellationError` normalization on a cancellation win, mapped original errors on ordinary eager failure, no libsmb2 connect and no resource creation after a cancellation win), the D8 recorded-cause teardown lifecycle (local close vs unsolicited post-ready events, driven through the injected driver), the TLS trust matrix, and Linux routing for all three kinds; integration/interop plan against Samba 4.23+ (`server smb transports = +quic`) and/or Windows Server 2025 — the Docker story is constrained by the `quic.ko` kernel-module requirement, so interop may start as a documented manual procedure.

## Capabilities

### New Capabilities

- `quic-transport-apple`: The `NWProtocolQUIC`-backed `SMBTransport` conformer — the cancellable/deadline-bounded connect state machine with atomic outcome-selection-and-duty-assignment claiming (effects executed outside the lock by the assigned party, per the D7 start handoff) and handshake (ALPN `"smb"`, TLS 1.3, SNI), single-bidirectional-stream byte-pipe send/receive, the recorded-cause established-connection lifecycle distinguishing peer-EOF/local-close/abnormal-loss (design D8) and error mapping to `POSIXError`, TLS trust-policy enforcement, availability gating.
- `quic-connection-policy`: The rules governing when and how QUIC is used — explicit opt-in selection, numeric-host rejection (fail-closed acceptance table; `AI_NUMERICHOST` as primary classifier with a deterministic supplement if the platform misses a required form; independent of the TLS trust policy — `.insecureNoVerification` never bypasses it; non-numeric hostnames only), UDP/443 port defaulting, no-silent-fallback, the secure-by-default TLS trust policy with explicit opt-in cases, the dedicated QUIC connect-timeout contract (design D10), and the `SMB2Manager` configuration surface (snapshot semantics, copying, serialization, Swift-only ObjC posture, Linux routing).

### Modified Capabilities

- `transport-seam`: `SMBTransportKind.quic` changes from "reserved for a future milestone" to an implemented kind; the kind-dispatch requirement now builds a QUIC transport instead of throwing `ENOTSUP`.
- `transport-servicing`: Seam endpoint handling becomes transport-aware — the default port is 443 for `.quic` (445 for TCP); kind dispatch constructs `QUICTransportApple` and installs a kind-specific libsmb2 selector (`SMB2_TRANSPORT_AUTO` for `.tcp`/`.automatic` — unchanged; `SMB2_TRANSPORT_QUIC` for `.quic`); the client connect signature carries the QUIC configuration snapshot; `connectWithBridge` gains the cancellation-safe bridge-ownership handoff covering eager connect through seam installation, including the eager-completion reconciliation and claim-before-resource-creation install ordering (design D12).
- `api-reference`: Document the new public API surface (transport selection on `SMB2Manager`, QUIC TLS options, availability constraints) in `docs/API.md`.

## Impact

- **New code**: `AMSMB2/QUICTransportApple.swift` (Apple-only, `#if canImport(Network)`), plus two platform-neutral files that compile everywhere including Linux — `AMSMB2/SMBQUICConfiguration.swift` (the `SMBQUICConfiguration` options type) and `AMSMB2/QUICConnectionPolicy.swift` (numeric-host classification, per-kind default port/selector, connect-timeout normalization — the D4 policy layer kept out of the conformer). No new package dependencies — Network.framework only (explicitly not `swift-nio-quic`, MsQuic, ngtcp2, or quiche per #346).
- **New tests**: `AMSMB2Tests/QUICTransportAppleTests.swift`, `QUICConnectionPolicyTests.swift`, `QUICSeamConnectTests.swift`, `QUICTrustTests.swift`, `SMBQUICConfigurationTests.swift`, `SMB2ManagerTransportSettingsTests.swift`, `BridgeOwnershipHandoffTests.swift` (D12 transition table), and `SMB2QUICInteropTests.swift` (server-gated interop lane).
- **New docs**: `docs/INTEROP-QUIC.md` — the verified manual SMB-over-QUIC interop procedure (Samba 4.23+ with `quic.ko`), since the kernel-module requirement keeps this out of Docker CI.
- **Changed code**: `Context.swift` (kind dispatch at :1124–1130 including the per-kind `smb2_set_transport` selector, per-kind default port in `parseSeamEndpoint`, `connect`/`connectWithBridge` signatures for the configuration snapshot and hoisted parsing, and the D12 cancellation-safe bridge-ownership handoff across eager connect and seam installation), `AMSMB2.swift` (public transport selection, snapshot helper, NSCopying, NSSecureCoding/Codable of the new setting), `SMBTransport.swift` (doc comment for `.quic`), `docs/API.md`, `docs/ARCHITECTURE.md`, README, and three existing test files updated for the new signatures/seam behavior (`SMB2CBDataLifetimeTests.swift`, `SMB2SeamConnectOrderingTests.swift`, `SMB2ServicingLoopTests.swift`).
- **Unchanged**: the libsmb2 fork (the external-transport C seam and `smb2_get_timeout`/`smb2_service_timeout` timer hooks from the TCP milestone already provide everything QUIC needs), `TransportBridge`, the servicing loop, all SMB semantics (auth, signing, encryption happen inside the tunnel).
- **Platform**: the QUIC *transport* is Apple-only in this change (`#if canImport(Network)`), matching the seam itself; Linux keeps the legacy socket path, and `.quic` on Linux throws `ENOTSUP`. The *configuration* surface (`SMB2Manager.transportKind`, `quicConfiguration`, `SMBQUICConfiguration`) is platform-neutral and exists on all platforms — possible because trust anchors are DER `[Data]`, not `SecCertificate`. Runtime OS floor for QUIC (iOS 15 / macOS 12 / macCatalyst 15 / tvOS 15 / watchOS 8 / visionOS 1) is higher than the package floor — handled by availability gating, not by raising package minimums.
- **Testing infra**: Samba 4.23+ QUIC server needs the `quic.ko` kernel module (~Linux 6.14) — not viable in Docker-on-macOS CI today; interop testing lands as a documented, repeatable manual procedure plus whatever CI automation proves feasible.
- **Downstream**: unblocks RandomPlayer #347 (adopt pluggable transports in RandomPlayer).

## Review

**Verdict: APPROVED** (project-architect, 2026-07-25 — issued as APPROVED WITH CONDITIONS by a
fresh independent review of the complete live worktree after the fourth remediation pass, then
upgraded to APPROVED by the same reviewer after confirming all three conditions cleared
first-hand against the live worktree: every edited passage read, the factual claims in the new
scoping text checked against the code, no executable change since the mechanism review
[diffstat-accounted], affected suites re-run 41/0, `openspec validate --strict` clean. The
original review treated all prior verdicts as leads only, re-verified every load-bearing claim
first-hand, and re-ran all listed test commands itself: QUIC transport suite 30/0 both with and
without `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, endpoint/parser suites 11/0, full suite 260/0
with 67 server-gated skips, `openspec validate --strict` clean.)

The reviewer confirmed all three remediation items are **correctly implemented and genuinely
proven**: the close-waiter teardown is race-free (the `isClosed`/`teardownPending` pair is set
in one critical section, the handoff's two lock acquisitions strand no waiter, at most one loss
can ever exist, the local `driver` capture is the correct object, and no lock is held across
await/resume/start/cancel on any path added by the pass); the gated regression tests prove the
close-completion ordering deterministically (positive waiter-count observation, event-ordered
`close-returned`, one cancel for two concurrent closes, no wall-clock coordination); the
overflow fix is provably trap-free (intermediate bounded at 655,359, `strtol` semantics
preserved, endpoint rejection ordered before transport construction by reading, and NIOTS
range-checks rather than traps downstream, so the TCP path strictly improves); and the
`scripts/test-integration.sh` worktree copy is byte-identical to the pre-`0f7ea0e` content.

Three conditions were attached — all honesty-of-claims wording, no code changes — addressed in
the same pass and **confirmed cleared by the same reviewer against the live worktree**
(2026-07-25; the reviewer verified each edited site, including that `.ready` genuinely is
emitted by the start side effect and that `cancel()` clears both handlers, so the scoping
text's factual claims hold):

- **C1 (must fix)**: the unqualified "no driver start or network activity can ever occur after
  `close()` has returned" was narrowly false on the one committed-start path with **no parked
  loss** — `.ready` winning while `start()` had not yet returned, where `close()` cancels the
  driver itself and the tail of `start()` (`armReceive`) runs against a cancelled driver with
  cleared handlers (safe; nothing leaks or resumes twice). *Fixed by scoping every such claim
  to the parked committed-start teardown* in `QUICTransportApple.swift` (close doc comment and
  the gap test's doc comment), design.md D7 (with the explicit `.ready`-mid-`start()`
  paragraph, also avoiding a re-introduced unqualified "all resources" per observation O1),
  `specs/quic-transport-apple/spec.md` (both the scenario AND-clause and the close
  requirement), `docs/ARCHITECTURE.md`, and the proposal summary sentence.
- **C2 (should fix)**: design.md described `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` as a
  "width-1 cooperative executor"; it disables cooperative-pool overcommit and does not force
  width 1. *Fixed*: the structural argument (the only blocking wait sits on a GCD worker) is
  stated as the proof, with the strict-pool green run recorded as corroborating evidence.
- **C3 (should fix)**: the superseded banner said "third remediation pass" while tasks.md §7
  and the inline annotations say fourth. *Fixed*: reconciled to "fourth".

Non-blocking observations recorded by the reviewer, left intentionally unfixed as pre-existing
or cosmetic: O1 (a pre-schedule loss can leave the armed deadline timer to self-expire within
`connectTimeout` — bounded, weak-self, benign; the D7 scoping paragraph now accounts for it),
O2 (dead `lifecycle = .localClosing` assignment immediately overwritten), O3 (`receive()`
resumes its continuation inside the lock — safe, never suspends, pre-existing), O4 (parser-
level boundary coverage for port 1 — *added anyway* as a one-line assertion), O5 (duplicate
file header in `QUICSeamConnectTests.swift`, cosmetic), O6 (double-`connect()` on one instance
guarded by documented contract only — unreachable via `SMB2Client`, pre-existing).

> **STATUS: SUPERSEDED (2026-07-25).** The APPROVED verdict below predates
> the fourth remediation pass (close()-completes-teardown contract, overflow-safe endpoint port
> parsing, non-blocking gated race tests) and is therefore stale for the current worktree. It is
> preserved as history only. The current verdict is recorded above this block.

**Verdict: APPROVED** (project-architect, 2026-07-25 — both conditions of the same reviewer's
APPROVED WITH CONDITIONS verdict cleared in task 6.7 and **confirmed against the live worktree**
by that reviewer, which then upgraded the verdict to APPROVED.)

The clearance was verified clause by clause, not accepted: the `ETIMEDOUT` description built
from `lastWaitingError`, the started case cancelling exactly once via the `.started` `LossDuty`,
the pre-commit case suppressed by `guard mayStart else { return }` and matching
`testDeadlineWinsBeforeStartSuppressesDriverStart`'s `cancelCount == 0`, the post-`.ready`
deadline fire being a genuine no-op (`deadline.cancel()` sits after `guard let duty`), and
`close()`'s reference release on all three branches of `consumeLossClaimLocked`. No instance of
the over-claim class remains anywhere in the artifact set, source comments, or docs.

Two findings from the clearance are recorded because they are the reason the neighbouring
scenarios are correct, and are not obvious from the text alone:

- **The three race scenarios ("Cancellation while waiting", "Ready-versus-cancel",
  "Failure-versus-cancel") cannot reach the pre-commit phase at all** — not merely by premise,
  but by mechanism: production installs `stateUpdateHandler` before `connection.start(queue:)`,
  and `ScriptedQUICDriver.emit(_:)` reads an `onState` that is assigned only inside `start()`,
  so a pre-start `emit` is a silent no-op. `startPhase == .notStarted` is unreachable for those
  premises.
- **Those scenarios are additionally robust because none of them attributes the cancel to a
  particular party** — they assert duty *accounting* (one cancel, one resume), which is
  invariant across every phase once the driver has been started. That is exactly what the two
  corrected scenarios lacked: they asserted a cancel in a phase where the count is zero. Future
  scenario authors should assert accounting, not attribution.

Two adjacent cases traced during the clearance, both clean and recorded so they need not be
re-derived: a `.ready` emitted synchronously from inside `start()` resumes success while
`startPhase == .starting`, after which the handoff finds `pendingLoss == nil` and does nothing
(driver retained, one resume); and the invalid-port `.failed` path satisfies the
"Failure-versus-cancel race" premise while holding no `NWConnection`, so the single issued
`cancel()` reaches a driver with nothing to cancel — still exactly one cancel and one resume,
with the port requirement separately and normatively guaranteeing no `NWConnection` is created.

The verdict is clear for `/opsx:verify` → `/opsx:archive` from an architectural standpoint. The
only acceptance not reproducible in review remains the manual SMB-over-QUIC interop gate in
`docs/INTEROP-QUIC.md`, already recorded as completed against the standing rig.

### Superseded: APPROVED WITH CONDITIONS (2026-07-25, second review of the remediation pass)

**Superseded by the APPROVED verdict above**, which is the same review after its two conditions
were cleared and confirmed. Preserved as history because it carries the substantive findings:

**Verdict: APPROVED WITH CONDITIONS** (project-architect, 2026-07-25 — fresh independent review
of the complete current artifact set; the second of the two reviews obtained during the
2026-07-25 remediation pass, performed against the live worktree with all prior verdicts treated
as leads only and every load-bearing anchor re-verified first-hand.)

The reviewer found **no behavioral defect, no design-level error, and no spec/implementation
divergence at requirement level**. It independently re-derived the D7 cleanup contract from
`connect()`, `resolveConnect(_:)`, `consumeLossClaimLocked(_:error:)` and `close()` and
confirmed the four-way table (pre-commit loss → winner cancels the deadline, nothing else;
commit-to-start loss → the *starting path* cancels deadline + driver after `start()` returns,
then resumes; post-start loss → the winner does both; `.ready` → the ready path cancels the
deadline and retains the driver) is now described accurately in design D7, the
`quic-transport-apple` requirement prose, the `resolveConnect` and `startPhase` doc comments,
`docs/ARCHITECTURE.md`, and proposal.md. It traced the port-validation error path end-to-end
(`initError` → synchronous `.failed(EINVAL)` from `start()` → parked loss → post-`start()`
handoff) and judged design D4's placement rationale sound rather than post-hoc. It confirmed
the phantom `claimConnectOutcome`/`ClaimedDuty` names survive only in permitted historical
text, and verified the `ENOTCONN` contract against **both** conformers. It also verified —
rather than accepted — the claim that the QUIC/TCP buffered-drain divergence is unobservable,
by checking that `TransportBridge.close()` cancels the inbound pump under the lock before
closing the transport, and agreed that recording the divergence beats changing either
conformer.

**Conditions (both required before archive; both satisfied in this pass).** Two normative
*scenarios* — pre-handoff legacy text one level below the requirement prose the earlier rounds
corrected — still asserted unconditional cancellation:

1. `specs/quic-transport-apple/spec.md` "Deadline expiry" claimed the `NWConnection` "is
   cancelled exactly once". This was **falsified by a shipped, passing test**:
   `testDeadlineWinsBeforeStartSuppressesDriverStart` asserts `driver.cancelCount == 0`,
   because a deadline winning at `startPhase == .notStarted` forbids the start and cancels
   nothing. Archiving it would have written a false acceptance criterion into
   `openspec/specs/`. **Fixed**: the cancel is now scoped to the already-started case, with the
   pre-commit suppression stated explicitly.
2. The same over-claim in the "Close while connecting" scenario. **Fixed** the same way.

Non-blocking, recorded faithfully and not fixed here: `GatedStartDriver.start()` blocks on a
`DispatchSemaphore` on a cooperative-pool thread — correct and green on multi-core hosts, but a
starvation (hang) hazard on a single-core CI runner *(fixed in the fourth pass, task 7.3: start
and the handoff moved to a dedicated non-cooperative queue, bounded wait with diagnostic)*;
`parseLeadingPort` accumulates port digits
into `Int` with no overflow guard, so an absurdly long numeric port traps instead of yielding
the documented `EINVAL` *(this review's "pre-existing, belongs to the separate `.tcp`
port-validation follow-up" classification was **wrong** and is corrected in the fourth pass:
the active `quic-connection-policy` requirement normatively covers every explicit port "65536
and larger", so a trap for a larger value was in scope for this change — fixed in task 7.2
with overflow-safe parsing and hoisted endpoint validation)*; `SMB2ServicingLoopTests.swift:298` still uses
implementation-batch vocabulary ("Since Batch B"), cosmetic; and the post-close seam contract
(`receive()` → empty `Data`, `send()` → `ENOTCONN`) is normative only in the QUIC capability
spec although it is a seam-wide contract shared with `TCPTransportApple` — its proper home is
`transport-seam`, worth a follow-up change.

Transport-seam acceptance beyond the unit suite (the full Samba matrix through
`QUICTransportApple`) still rests on the manual interop gate recorded in
`docs/INTEROP-QUIC.md`, which this review did not and could not re-run.

### Superseded: NEEDS REVISION (2026-07-25, first review of the remediation pass)

**Superseded by the APPROVED WITH CONDITIONS review above.** Preserved as history:

**Verdict: NEEDS REVISION** (project-architect, 2026-07-25 — fresh independent review of the
live worktree, obtained after the tasks-6.5 corrections.) It confirmed all three blocking
defects from the pre-remediation review were genuinely fixed, and that the port-validation
decision (area 2) and the state-machine symbol rename (area 3) fully passed — tracing the
`initError` → synchronous `.failed(EINVAL)` → parked-loss error path first-hand and judging the
D4 placement rationale sound rather than post-hoc. It found **two surviving instances of the
same two defect classes**, in sections the 6.5 round had not named:

1. `specs/quic-transport-apple/spec.md` — the "No double resume or leaked continuation"
   scenario still read "the winning path alone performs cleanup", contradicting that spec's own
   corrected requirement prose and falsifying the parked commit-to-start case.
2. `design.md` D3 **and** the `receive()` source comment in `QUICTransportApple.swift` still
   read "`ENOTCONN` is reserved for the never-connected case", contradicting the corrected spec
   and the shipped `send()` on both conformers.

Both were repaired in tasks 6.6, together with four of its non-blocking findings (the same
winner-performs-cleanup phrasing in `docs/ARCHITECTURE.md`; this change's own over-broad
"matches `TCPTransportApple` exactly" post-close claim, narrowed with the buffered-drain
divergence recorded; the undocumented cost of the parked window; and the three modified test
files missing from the Impact list). Its durable lesson — sweep for the offending *phrases*
repo-wide rather than only the sections a review names — is recorded in task 6.6 and was
applied in 6.7.

### Superseded: NEEDS REVISION (2026-07-25, pre-remediation)

The verdict below is **superseded by the APPROVED WITH CONDITIONS review above**. Its three
blocking defects were repaired (tasks 6.5), and the two follow-up rounds repaired the surviving
instances of the same defect classes that it had not named (tasks 6.6, 6.7). Preserved as
history:

**Verdict: NEEDS REVISION** (project-architect, 2026-07-25 — fresh independent review of the
complete current artifact set, required because the previously recorded APPROVED verdict
(2026-07-24, preserved below as superseded history) predates the post-implementation
adversarial-fix round (tasks 6.1–6.4: the D7 atomic start/loss handoff, the throwing
`QUICTransportApple(configuration:)` initializer contract, driver port validation) and the
subsequent artifact-sync corrections, and therefore cannot vouch for the current artifact
set.)

The reviewer verified the material deltas first-hand and found **no behavioral defect and no
spec/implementation divergence in any of the five spec deltas**: the D7 start/loss handoff
(design.md:380–392, `quic-transport-apple` spec, `QUICTransportApple.swift:117-136/242-264/
296-314`), the initializer contract (throwing `QUICTransportApple(configuration:)` deriving
the timeout via `normalizedQUICConnectTimeout`, internal
`init(configuration:connectTimeout:driverFactory:deadline:)`, double validation hoisted +
in-initializer — with no stale `connectTimeout:` public-argument reference surviving anywhere
in artifacts, docs, or README), the port behavior (`EINVAL`, no `NWConnection`, boundaries
preserved), and D7/D8/D10/D12 mutual consistency all match the implementation. The blocking
defects are confined to `design.md` plus one false claim in `tasks.md`; all three required
fixes are bounded text edits (no code change, no spec behavior change):

1. **D7's cleanup summary contradicts the shipped start/loss handoff.** The updated handoff
   bullet (design.md:380–392) is correct, but two later statements — "the timer is cancelled
   by whichever path wins" (design.md:423–424) and "Cleanup is the winner's duty … the
   deadline timer is cancelled by the winner" (design.md:430–433) — are false in the parked
   (`startPhase == .starting`) case, where the winning claim parks the loss and performs no
   teardown; the *starting path* performs `deadline.cancel()` and `driver.cancel()` after
   `start()` returns (`QUICTransportApple.swift:296-314`, `:353-354`, `:252-264`,
   `:554-568`). Not editorial: a maintainer trusting the summary would move the cancel back
   into the winner and reintroduce exactly the cancel-before-start-side-effect bug task 6.1
   fixed. Required fix: restate the cleanup duty as *assigned by the start handoff*
   (pre-commit: nothing to cancel; commit-to-start: starting path cancels timer + driver then
   resumes; post-start: winner does both).
2. **The port contract exists in specs/docs/tasks but nowhere in `design.md`, and task 6.4
   falsely claims otherwise.** The 1...65535 / `EINVAL` / no-`NWConnection` contract is
   normative in `quic-connection-policy` (spec.md:111–131), documented (`api-reference`,
   docs/API.md:711), and implemented (`QUICTransportApple.swift:689-702`), but no port-range
   decision appears anywhere in the design, while tasks.md task 6.4 (checked) claims
   "specs/design updated for the handoff, initializer, and port contracts". The placement is
   architecturally notable and unrecorded: it is the only `.quic` validation that runs
   *after* transport construction — the driver's `start()` synchronously emits
   `.failed(EINVAL)` inside the commit-to-start window, so the error reaches the caller
   through the parked-loss handoff rather than the hoisted client validation step. Required
   fix: add the port contract and its placement rationale to D4 (or D2) and correct or
   re-scope task 6.4's claim.
3. **`claimConnectOutcome(_ outcome: ConnectOutcome) -> ClaimedDuty?` is a phantom symbol**
   (design.md:361, :413, :621, :714; tasks.md:98; echoed in a `Context.swift:1125` comment).
   The shipped factoring is `resolveConnect(_ outcome: ConnectOutcome)` plus
   `consumeLossClaimLocked(_:error:) -> LossDuty?`, with the duty executed inside
   `resolveConnect`, not returned to a caller. Every other named signature in the design
   matches the code exactly. Required fix: rename to the real symbols.

Non-blocking advisories, recorded faithfully: stale shipped code comments contradicting the
specs (`Context.swift:1265-1272` "not yet constructed in this batch" / "later batch";
`QUICSeamConnectTests.swift:20/:101-102` "Batch-A stub" wording); proposal Impact drift (new
files `AMSMB2/QUICConnectionPolicy.swift` and `AMSMB2/SMBQUICConfiguration.swift` plus
`docs/INTEROP-QUIC.md` not listed); the unrelated uncommitted `scripts/test-integration.sh`
teardown-masking fix (record-only, not to be reverted); stale pre-change line anchors in
design.md acceptable as baseline prose; and the `quic-transport-apple` spec's "reserved for a
never-connected transport" over-reach for `ENOTCONN`, which `send()` after `close()` also
throws (consistent with `TCPTransportApple`).

The change MUST NOT be archived until the three blocking design/tasks defects are repaired
and re-reviewed by the project-architect.

### Superseded: APPROVED (2026-07-24)

The verdict below is **superseded by the 2026-07-25 NEEDS REVISION review above** — it
predates the post-implementation adversarial-fix round (tasks 6.1–6.4) and the artifact-sync
corrections, so it does not cover the current artifact set. Preserved as history:

**Verdict: APPROVED** (project-architect, 2026-07-24 — fresh independent review of the
complete artifact set after the fourth repair round, with the full eight-file diff and every
load-bearing code anchor verified first-hand: `TCPTransportApple.connect`'s
cancellation-to-`ECANCELED` mapping on all three exit paths (`TCPTransportApple.swift:165/
170/178`), `TransportBridge.connect` rethrow-unchanged and idempotent `close()`
(`TransportBridge.swift:257-261/:153-182`), `makeExternalTransport()`'s `ext.userdata`
retain contract (`:200-244`), `mapTransportConnectError` pass-through
(`Context.swift:1189-1194`), the current install-block ordering — `cbPtr` created first at
`Context.swift:1240`, `makeExternalTransport()` at `:1255`, `transportBridge` at `:1299`,
abandonment re-check at `:1322` — and `teardownSeam()`'s exactly-once nil-swap close at
`:1514-1526`).

The fresh review found no blocking artifact defects and attached **no conditions**. Its
findings, copied faithfully: the eager-completion reconciliation table is complete and total
(inputs are handoff state × success/failure × cancellation-won — deliberately not error
shape; rows A–D plus rule E cover every cell; exactly one `bridge.close()` in every non-A
outcome; no interleaving closes twice, closes zero times, or leaks a bridge, retain,
continuation, or pending operation); precedence rule E is well-defined by commit order to the
single reconciliation lock and deterministically testable in both orders; normalization to
`CancellationError` is correctly scoped to a committed cancellation win, with a spontaneous
`ECANCELED` in `eagerConnecting` rethrown as the mapped original error (row D); the
claim-before-creation install ordering has no double-release and no new leak, with each
failure path releasing exactly what exists at that point; no artifact assumes the TCP path
throws `CancellationError` directly and no live-normative text claims a Darwin classifier
supplement is empirically required; and D7/D8/D12 are mutually consistent (ready-after-cancel
routes the single close through D8's local-close path while D7's losing `onCancel` never
cancels the connection). One **non-blocking advisory**, editorial only and explicitly not a
condition: reconciliation row C's condition column ("cancellation-shaped failure") reads
narrower than rule E's state-keyed decision; the `(cancelled, non-cancellation-shaped
failure)` behavior is nevertheless fully specified by the reconciliation-inputs sentence,
rule E, and the cancellation-racing-ordinary-failure scenario and its required task-1.5 test,
so it is not an unresolved gap — an optional future editorial pass may widen row C's
condition to "failure (any error)".

The previously recorded "APPROVED WITH CONDITIONS" verdict (2026-07-24, the fresh review
after the third repair round) was **withdrawn**, together with its "no further artifact
defects" finding, because D12 still contained artifact defects at the time it was recorded:

1. **D12 contradicted the TCP cancellation contract.** D12's `eagerConnecting` rule said
   cancellation during the eager connect performs no close and "makes `bridge.connect` throw
   `CancellationError`". In fact `TCPTransportApple.connect` converts task cancellation to
   `POSIXError(.ECANCELED)` (`TCPTransportApple.swift:169-170`), `TransportBridge.connect`
   propagates that error unchanged, and `mapTransportConnectError` passes `POSIXError`
   through untouched — while the `transport-servicing` requirement simultaneously demanded
   exactly one `bridge.close()` and a caller-visible `CancellationError` whenever
   cancellation wins before installation. Ordinary (non-cancellation) eager `bridge.connect`
   failure had no explicit D12 state transition or cleanup duty at all. Resolved in the
   fourth repair round by the eager-completion reconciliation transition (design D12, the
   `transport-servicing` requirement, task 1.5), which normalizes a cancellation win to
   `CancellationError` at the reconciliation and assigns every close duty explicitly.
2. **D12's pointer-creation ordering contradicted itself.** It called the lock-protected
   `localOwned → installing` claim the install block's first action while its failed-claim
   branch released `cbPtr` — a pointer that, in the current code, is created at the top of
   the install block before any claim could run (`Context.swift:1240`). Resolved in the
   fourth repair round: the claim is normatively the install block's first step; a failed
   claim creates nothing (no `cbPtr`, no `Unmanaged.passRetained(cb)`, no
   `makeExternalTransport()`, no `ext.userdata` retain, no libsmb2 call) and therefore has
   nothing to release; `cbPtr` and the external-transport retain exist only after a
   successful claim.

The withdrawn review also asserted an unsupported empirical prediction — that Darwin's
`getaddrinfo(AI_NUMERICHOST)` "will very likely reject" the legacy numeric forms and that a
classifier supplement is therefore required on Darwin. A live Darwin
`getaddrinfo(AF_UNSPEC, SOCK_STREAM, AI_NUMERICHOST)` probe on the current development
machine classified all required forms (`127.1`, `2130706433`, `0x7f000001`, `0177.0.0.1`,
`fe80::1%en0`) as numeric. That single-machine observation is likewise not generalized: the
normative policy is platform-neutral — the complete table remains acceptance criteria, tests
run on every supported platform, `AI_NUMERICHOST` remains the primary classifier, and a
deterministic supplement is added only on platforms/forms where the empirical test
demonstrates a miss. Platform tests determine whether any deterministic supplement is
required; no assumption is made in advance about a particular Darwin or libc version.

History, preserved: an adversarial review found eight defects in the original artifacts
(cross-platform TLS type that could not compile on Linux, undefined configuration plumbing,
incomplete numeric-host rejection, unspecified QUIC connect state machine, ambiguous TLS
trust contract, overstated disconnect guarantees, NSCopying dropping the new settings, and an
implementation-defined libsmb2 selector). A second adversarial round found eight further
defects in the repaired artifacts (connect outcome selection not atomic with side effects,
wrong TLS verify-block accessor and underspecified custom-roots sequence, incoherent QUIC
connect-timeout semantics vs the `SMB2Manager.timeout` contract, the Network-gated client
signature described as the universal route on Linux, nondeterministic TEST-NET unit tests,
"graceful EOF" misapplied to the local-close signal, an unresolved Objective-C compatibility
decision, and "DNS names only" hostname wording). Both rounds were repaired (designs
D5/D6/D7/D10/D11 and the matching spec/task updates). An earlier "APPROVED WITH CONDITIONS /
zero remaining artifact defects" verdict had already been withdrawn as unsupported; the third
repair round (2026-07-24) resolved its three outstanding defects (the
ready-wins-but-task-cancelled ownership gap → D12 handoff; the D7/D8 post-ready `.cancelled`
contradiction → the recorded-cause lifecycle; the numeric-table weakening condition built on
a false fail-closed claim → the acceptance-criteria table independent of the TLS trust
policy). The load-bearing code anchors verified first-hand during the third-round review
remain valid and are recorded in the reviewer memory (eager `bridge.connect` at
`Context.swift:1222` preceding the cancellation handler at `:1235`, `transportBridge`
assignment at `:1299`, `teardownSeam()` closing only via `transportBridge`,
`TCPTransportApple.signalClosed()`, `SMB2_TRANSPORT_*` semantics in the fork, the Linux-only
legacy connect, and `smb2_set_timeout` gating).

The post-fourth-round review recorded in this subsection superseded the withdrawn verdicts;
its findings are copied verbatim at the top of this subsection. It is in turn superseded by
the 2026-07-25 NEEDS REVISION review at the top of this Review section.
