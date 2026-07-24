# Proposal: add-quic-transport

## Why

The pluggable-transport milestone (RandomPlayer #344/#345, AMSMB2 #28) landed the `SMBTransport` seam and flipped Apple platforms onto it, but `SMBTransportKind.quic` is still a reserved case that throws `ENOTSUP` (`Context.swift:1128`). SMB-over-QUIC (UDP/443, TLS 1.3) is the core feature of the current milestone (AMSMB2 #29, RandomPlayer #346): it lets the client reach Windows Server 2025 / Samba 4.23+ file servers over untrusted networks where TCP/445 is blocked, and it unblocks RandomPlayer #347.

## What Changes

- Add `QUICTransportApple`, a new `SMBTransport` conformer backed by Network.framework QUIC (`NWProtocolQUIC`) — system QUIC, nothing to ship, App-Store-safe. Availability-gated (`@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)`; Package.swift's floors — including `.macCatalyst(.v13)` — are unchanged); older OS versions fail with `ENOTSUP`. Its `connect` is a self-contained, deadline-bounded, cancellable state machine over `NWConnection` whose outcome selection and side effects are a single atomic, lock-protected transition (design D7) — it cannot rely on libsmb2's timeout machinery, which is not yet installed during the eager transport connect; the deadline comes from a dedicated `SMBQUICConfiguration.connectTimeout` (default 30 s, design D10), independent of `SMB2Manager.timeout`'s "zero/negative disables" contract. On the client side, `SMB2Client.connectWithBridge` guards the entire interval from before the eager `bridge.connect` through seam installation with a lock-protected bridge-ownership handoff (design D12): exactly one owner is responsible for closing the bridge at every point — the eager-completion reconciliation after `bridge.connect` returns (which closes the still-local bridge exactly once on every cancellation or failure outcome and normalizes a cancellation win to `CancellationError`, regardless of the conformer's internal cancellation error — `TCPTransportApple` maps cancellation to `POSIXError(.ECANCELED)`, the QUIC machine throws `CancellationError`), the cancellation handler while the bridge is locally owned, or the installed seam's `teardownSeam()` — and `smb2_set_transport`/`smb2_connect_share_async` never begin once cancellation has won.
- Wire mapping follows the Microsoft/Samba interop behavior (verified against Samba's client implementation, `source3/libsmb/smbsock_connect.c`): ALPN token `"smb"`, TLS 1.3, one QUIC connection with a **single bidirectional stream used as a byte pipe**. The stream carries the exact same framed SMB2 byte stream as direct TCP (4-byte transport length prefix included) — libsmb2 keeps doing all SMB framing/auth inside the tunnel; the transport stays a dumb pipe, same as `TCPTransportApple`.
- Connection policy (per #346 — "don't get these wrong"):
  - QUIC is **explicit opt-in** — never auto-selected; `.automatic` continues to mean TCP.
  - **Numeric hosts rejected** — any host the platform resolver classifies as a numeric IPv4/IPv6 address *without DNS* (`getaddrinfo` with `AI_NUMERICHOST`) is refused, including legacy forms such as `127.1`, `2130706433`, hex/octal IPv4, and scoped IPv6 (`fe80::1%en0`) — not just canonical `inet_pton` literals (mirrors Samba/Windows client behavior). The required rejection table is acceptance criteria: if the platform classifier misses a listed form, the classifier is supplemented with deterministic parsing — the table is never weakened (design D4). Rejection runs before the TLS trust policy is applied and is independent of it; `.insecureNoVerification` never bypasses it (with chain and hostname verification disabled, no later validation layer would catch a numeric target).
  - Default port **UDP/443** when the server string has no explicit port (TCP keeps 445).
  - No silent TCP fallback: a QUIC connect failure surfaces as an error; falling back is the caller's decision.
- TLS security surface: system trust evaluation and hostname verification by default — **never insecure by default**. Trust is a mutually exclusive policy (`system` / `customRoots` / `insecureNoVerification`, design D5): custom DER trust anchors (covering private-CA and self-signed server certificates) *replace* system roots and keep hostname verification; the insecure escape hatch is a separate, explicit case. Certificate/SPKI *pinning* is explicitly **not** part of this change.
- Public API: `SMB2Manager` gains transport selection (today `connect(shareName:encrypted:)` hardcodes `.automatic`, `AMSMB2.swift:1511`) plus `SMBQUICConfiguration`, a platform-neutral options type (trust anchors as DER `[Data]`, converted to `SecCertificate` only inside the Apple transport — so the type compiles and exists on Linux; plus the `connectTimeout` knob, design D10). The manager snapshots both settings under its `connectLock` before suspending; on Apple the immutable snapshot flows through `SMB2Client.connect(server:share:user:transportKind:quicConfiguration:)` (a `#if canImport(Network)` signature) into the transport initializer (design D6), where `.quic` constructs `QUICTransportApple` instead of throwing; on Linux the manager routes on the same snapshot (`.quic` → `ENOTSUP` before any network activity, `.tcp`/`.automatic` → the legacy path unchanged). Copying (`NSCopying`) preserves both settings. The new surface is intentionally Swift-only — not Objective-C-representable and not exposed to ObjC; the existing ObjC API is unchanged (design D11).
- Disconnect semantics are unchanged (option B, design D8): `TransportBridge` is untouched; the SMB DISCONNECT PDU remains best-effort local (queued and flushed into the bridge, but teardown may cancel the outbound pump before wire delivery). "Graceful disconnect" is **not** claimed as a guaranteed interop result; the transport distinguishes peer-originated graceful EOF, local close, and abnormal loss through an explicit recorded-cause lifecycle (design D8): local `close()` records its cause before cancelling the `NWConnection`, so the resulting `.cancelled` event is never misread as abnormal transport loss, while an unsolicited post-ready `.failed` or `.cancelled` remains abnormal loss.
- Tests: unit tests for policy (table-driven numeric-host rejection, port defaulting, opt-in dispatch, availability gating, connect-timeout boundary cases), configuration plumbing/snapshot semantics, `NSCopying`/`NSSecureCoding`/`Codable` of the new settings, the connect state machine — driven deterministically through injected connection-driver and deadline-scheduler seams (cancellation, deadline, completion races, and connection-ownership/side-effect assertions; no wall-clock or TEST-NET dependence, design D7) — the D12 bridge-ownership handoff (transition-table unit tests covering every eager-completion reconciliation outcome and race order, plus MockTransport-backed coverage: exactly-once close in every outcome, internal-`ECANCELED`-to-`CancellationError` normalization on a cancellation win, mapped original errors on ordinary eager failure, no libsmb2 connect and no resource creation after a cancellation win), the D8 recorded-cause teardown lifecycle (local close vs unsolicited post-ready events, driven through the injected driver), the TLS trust matrix, and Linux routing for all three kinds; integration/interop plan against Samba 4.23+ (`server smb transports = +quic`) and/or Windows Server 2025 — the Docker story is constrained by the `quic.ko` kernel-module requirement, so interop may start as a documented manual procedure.

## Capabilities

### New Capabilities

- `quic-transport-apple`: The `NWProtocolQUIC`-backed `SMBTransport` conformer — the cancellable/deadline-bounded connect state machine with atomic outcome-and-side-effect claiming and handshake (ALPN `"smb"`, TLS 1.3, SNI), single-bidirectional-stream byte-pipe send/receive, the recorded-cause established-connection lifecycle distinguishing peer-EOF/local-close/abnormal-loss (design D8) and error mapping to `POSIXError`, TLS trust-policy enforcement, availability gating.
- `quic-connection-policy`: The rules governing when and how QUIC is used — explicit opt-in selection, numeric-host rejection (fail-closed acceptance table; `AI_NUMERICHOST` as primary classifier with a deterministic supplement if the platform misses a required form; independent of the TLS trust policy — `.insecureNoVerification` never bypasses it; non-numeric hostnames only), UDP/443 port defaulting, no-silent-fallback, the secure-by-default TLS trust policy with explicit opt-in cases, the dedicated QUIC connect-timeout contract (design D10), and the `SMB2Manager` configuration surface (snapshot semantics, copying, serialization, Swift-only ObjC posture, Linux routing).

### Modified Capabilities

- `transport-seam`: `SMBTransportKind.quic` changes from "reserved for a future milestone" to an implemented kind; the kind-dispatch requirement now builds a QUIC transport instead of throwing `ENOTSUP`.
- `transport-servicing`: Seam endpoint handling becomes transport-aware — the default port is 443 for `.quic` (445 for TCP); kind dispatch constructs `QUICTransportApple` and installs a kind-specific libsmb2 selector (`SMB2_TRANSPORT_AUTO` for `.tcp`/`.automatic` — unchanged; `SMB2_TRANSPORT_QUIC` for `.quic`); the client connect signature carries the QUIC configuration snapshot; `connectWithBridge` gains the cancellation-safe bridge-ownership handoff covering eager connect through seam installation, including the eager-completion reconciliation and claim-before-resource-creation install ordering (design D12).
- `api-reference`: Document the new public API surface (transport selection on `SMB2Manager`, QUIC TLS options, availability constraints) in `docs/API.md`.

## Impact

- **New code**: `AMSMB2/QUICTransportApple.swift` + `SMBQUICConfiguration` (platform-neutral file, compiles on Linux). No new package dependencies — Network.framework only (explicitly not `swift-nio-quic`, MsQuic, ngtcp2, or quiche per #346).
- **Changed code**: `Context.swift` (kind dispatch at :1124–1130 including the per-kind `smb2_set_transport` selector, per-kind default port in `parseSeamEndpoint`, `connect`/`connectWithBridge` signatures for the configuration snapshot and hoisted parsing, and the D12 cancellation-safe bridge-ownership handoff across eager connect and seam installation), `AMSMB2.swift` (public transport selection, snapshot helper, NSCopying, NSSecureCoding/Codable of the new setting), `SMBTransport.swift` (doc comment for `.quic`), `docs/API.md`, `docs/ARCHITECTURE.md`, README.
- **Unchanged**: the libsmb2 fork (the external-transport C seam and `smb2_get_timeout`/`smb2_service_timeout` timer hooks from the TCP milestone already provide everything QUIC needs), `TransportBridge`, the servicing loop, all SMB semantics (auth, signing, encryption happen inside the tunnel).
- **Platform**: the QUIC *transport* is Apple-only in this change (`#if canImport(Network)`), matching the seam itself; Linux keeps the legacy socket path, and `.quic` on Linux throws `ENOTSUP`. The *configuration* surface (`SMB2Manager.transportKind`, `quicConfiguration`, `SMBQUICConfiguration`) is platform-neutral and exists on all platforms — possible because trust anchors are DER `[Data]`, not `SecCertificate`. Runtime OS floor for QUIC (iOS 15 / macOS 12 / macCatalyst 15 / tvOS 15 / watchOS 8 / visionOS 1) is higher than the package floor — handled by availability gating, not by raising package minimums.
- **Testing infra**: Samba 4.23+ QUIC server needs the `quic.ko` kernel module (~Linux 6.14) — not viable in Docker-on-macOS CI today; interop testing lands as a documented, repeatable manual procedure plus whatever CI automation proves feasible.
- **Downstream**: unblocks RandomPlayer #347 (adopt pluggable transports in RandomPlayer).

## Review

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

The fresh post-fourth-round review recorded above supersedes the withdrawn verdicts; its
findings are copied verbatim at the top of this section.
