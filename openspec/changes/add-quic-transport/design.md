# Design: add-quic-transport

## Context

The transport seam is in place: `SMBTransport` (`AMSMB2/SMBTransport.swift`) is a `Data`-based,
NIO-free/libsmb2-free byte-pipe protocol; `TransportBridge` + the no-fd servicing loop
(`Context.swift`) drive libsmb2 through it; `smb2_get_timeout`/`smb2_service_timeout` timer hooks
are already wired. `TCPTransportApple` (NIOTransportServices) is the only conformer;
`SMBTransportKind.quic` throws `ENOTSUP` at `Context.swift:1128`, and `SMB2Manager` hardcodes
`.automatic` at `AMSMB2.swift:1511`.

Governing issues: AMSMB2 #29 / RandomPlayer #346. Reference servers: Windows Server 2025 and
Samba 4.23+ (`server smb transports = +quic`; Linux server needs `quic.ko`, ~6.14 kernels).

**Interop facts established during proposal research** (Samba client source,
`source3/libsmb/smbsock_connect.c`, `source4/lib/tls/tls.h`):

- ALPN token is the literal `"smb"` (passed to `tstream_tls_ngtcp2_connect_send`).
- The client makes one QUIC connection and obtains **one bidirectional stream**
  (`tstream_context **quic_stream`), which then feeds the *same* SMB byte-stream machinery as a
  TCP socket — i.e. the stream is a byte pipe carrying SMB2 PDUs with the standard 4-byte direct
  transport length prefix; all SMB auth/signing/encryption happens inside the tunnel.
- Samba's QUIC client only supports **name-based UNCs**; IP-based targets are rejected.
- Microsoft: UDP/443 default, TLS 1.3, server-certificate tunnel; client opt-in via
  `/TRANSPORT:QUIC` (no auto-switch except Windows' own TCP-first fallback policy).

This means QUIC slots into the existing seam with **no libsmb2 fork changes and no
TransportBridge changes**: `QUICTransportApple` is a sibling of `TCPTransportApple` with a
different wire under the same byte-pipe contract.

## Goals / Non-Goals

**Goals:**

- `QUICTransportApple: SMBTransport` on Network.framework `NWProtocolQUIC`, ALPN `"smb"`,
  TLS 1.3, single bidirectional stream, byte-pipe semantics identical to the TCP conformer
  (incremental inbound buffering, empty-`Data` EOF, `POSIXError` mapping).
- Enforced connection policy: explicit opt-in, name-based hosts only, UDP/443 default, no
  silent TCP fallback.
- Secure-by-default TLS: system trust + hostname verification; explicit opt-in overrides only.
- Public transport selection on `SMB2Manager` without breaking existing API/serialization.
- Unit-testable policy layer; documented interop procedure against Samba 4.23+/WS2025.

**Non-Goals:**

- Linux QUIC client support (seam itself is Apple-only today; ngtcp2/MsQuic fallback is a later
  milestone if ever).
- SMB multichannel-over-QUIC, connection migration tuning, 0-RTT early data (explicitly not
  used — replayable early data is a security foot-gun and unnecessary for SMB).
- Automatic TCP→QUIC or QUIC→TCP fallback inside the library; `automatic` keeps meaning TCP.
- Client-certificate authentication (WS2025 client-access-control) — surface can be added to the
  options type later without breaking changes.
- Fixing the pre-existing perf/lifecycle issues (#44–#46, #49) — separate work.

## Decisions

### D1: Network.framework `NWProtocolQUIC`, used directly (not via NIOTS, not swift-nio-quic)

NIOTransportServices has no QUIC bootstrap, so unlike `TCPTransportApple` the QUIC conformer
talks to `NWConnection` directly. System QUIC ships with the OS (nothing to bundle,
App-Store-safe, LGPL-irrelevant), gets TLS 1.3 + cert handling from Security.framework, and is
the #346-mandated first choice. Alternatives rejected: `apple/swift-nio-quic` (API explicitly
unstable), MsQuic/ngtcp2 (ship a C library + crypto stack; portable fallback for a *later*
milestone), quiche (Rust + BoringSSL build burden).

Consequence: availability floor is
`@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)` — the
macCatalyst floor is spelled out explicitly because Package.swift declares `.macCatalyst(.v13)`,
so Catalyst is a first-class destination whose floor must not be left implicit. This is higher
than the package floor (iOS 13 / macOS 10.15 / macCatalyst 13). The class and the `.quic`
dispatch arm are availability-gated; on older OSes `.quic` fails with `POSIXError(.ENOTSUP)` at
runtime (package floors do not change). Verification: unit tests assert the gated dispatch, and
the availability annotation (including macCatalyst 15) is verified by code inspection plus a
macCatalyst build check in the pre-archive sweep (task 5.3).

### D2: Wire mapping — one bidirectional stream, byte-pipe, framing untouched

`NWConnection` is created with `NWParameters(quic:)`; the connection's initial bidirectional
stream carries everything. `send(_:)` writes the bytes libsmb2 hands the seam **verbatim**
(libsmb2 already emits the 4-byte length-prefixed PDU stream); `receive()` returns whatever
chunks arrive. No SMB awareness in the transport — same contract `MockTransport` and
`TCPTransportApple` honor. ALPN `"smb"` and SNI = target hostname are set via
`sec_protocol_options` on the QUIC options. We do **not** invent per-request streams: neither
Samba nor Windows maps SMB2 message multiplexing onto QUIC stream multiplexing; SMB2 credits/
MessageId multiplexing continues inside the single stream exactly as over TCP.

**Must-verify at first interop run** (highest-risk detail per #346): the 4-byte prefix presence
on the QUIC stream. All evidence (Samba reuses its TCP byte-stream reader on the QUIC tstream)
says it is present. If interop proves otherwise, the fix lands in the libsmb2 fork's seam layer
(frame stripping), not in Swift — the transport stays a pipe either way.

### D3: Conformer shape mirrors `TCPTransportApple`

`public final class QUICTransportApple: SMBTransport, @unchecked Sendable` with `NSLock`-guarded
state and an inbound chunk-FIFO + waiter continuation, mirroring `TCPTransportApple`'s proven
structure (lock sections never contain `await`; `receive()` parks a single waiter; empty `Data`
from a *remote* stream close = peer-originated graceful EOF; close is idempotent and resumes the
parked waiter with **empty `Data`** — the local-close EOF signal (an empty-`Data` bridge teardown
signal, *not* a peer-originated graceful EOF; implemented via the D8 recorded-cause lifecycle,
which records the local-close cause *before* `NWConnection.cancel()` so the resulting
`.cancelled` event is never misread as abnormal loss), exactly like `TCPTransportApple.close()` → `signalClosed()`,
`TCPTransportApple.swift:429-437` — so `TransportBridge.inboundPump()` sees the identical
`setInboundEOF()` teardown signal from both conformers; `ENOTCONN` is reserved for the
never-connected case, matching `TCPTransportApple.receive()`'s `_channel == nil` guard).
`NWConnection.receive` re-arms itself and appends to the FIFO on the connection's private
`DispatchQueue`. Rationale: the seam + bridge were validated against this exact concurrency
shape; introducing an actor here would add a second pattern for no benefit. Alternative (actor)
rejected for consistency and because `NWConnection` callbacks would hop executors anyway.

### D4: Policy enforcement lives in `SMB2Client.connect(transportKind:)`, not in the transport

- **Plumbing restructure (required — the kind is not visible where parsing happens today)**:
  `parseSeamEndpoint` is currently called inside `connectWithBridge`, which never sees the
  `SMBTransportKind`, and `connect(...transportKind:)` constructs the transport before any
  parsing. The connect entry point therefore becomes kind- and configuration-aware and hoists
  the endpoint work. Concrete internal signatures:

  ```swift
  // SMB2Client (Context.swift, #if canImport(Network))
  func connect(
      server: String, share: String, user: String,
      transportKind: SMBTransportKind,
      quicConfiguration: SMBQUICConfiguration?      // immutable snapshot from the manager (D6)
  ) async throws

  static func parseSeamEndpoint(
      _ server: String, defaultPort: Int             // 445 for .tcp/.automatic, 443 for .quic
  ) throws -> (host: String, port: Int)

  func connectWithBridge(
      server: String, share: String, user: String,   // original server string still goes to libsmb2
      host: String, port: Int,                       // already-resolved endpoint
      bridge: TransportBridge,
      selector: Int32                                // SMB2_TRANSPORT_* constant chosen by the kind (D9)
  ) async throws
  ```

  `connect(...)` calls `parseSeamEndpoint(server, defaultPort:)`, runs host validation (below)
  and — for `.quic` — connect-timeout validation/normalization (D10), and only then constructs
  the transport — `TCPTransportApple()` for `.tcp`/`.automatic`, or
  `QUICTransportApple(configuration:connectTimeout:)` for `.quic`, receiving the configuration
  snapshot and the **validated, normalized** QUIC connect timeout (D10 — sourced from
  `SMBQUICConfiguration.connectTimeout`, never from `SMB2Client.timeout`) at construction —
  wraps it in the bridge, and calls
  `connectWithBridge`. Parsing happens exactly once, and validation precedes both transport
  construction and `bridge.connect()` (the eager-connect ordering). The transport never reads
  configuration from the manager or client after construction, so later settings changes cannot
  race with or mutate an in-flight or established connection.
- **Numeric-host rejection**: during that hoisted validation, `.quic` classifies the parsed host
  with `getaddrinfo(host, nil, &hints, &res)` where `hints.ai_flags = AI_NUMERICHOST`
  (`ai_family = AF_UNSPEC`, `ai_socktype = SOCK_STREAM`; `freeaddrinfo` on success). A return of
  `0` means the platform resolver accepts the string as a numeric address *without any DNS
  lookup* — this is deliberately the resolver's own classification, not `inet_pton`, and is
  *expected* to catch more than canonical literals: legacy IPv4 short/hex/octal forms (`127.1`,
  `2130706433`, `0x7f000001`, `0177.0.0.1`), IPv4-mapped IPv6, and scoped IPv6 (`fe80::1%en0`);
  wherever the platform's classifier does not, the deterministic supplement below covers them.
  Platform tests determine whether any deterministic supplement is required; no assumption is
  made in advance about a particular Darwin or libc version, in either direction (task 1.1
  runs the full table empirically on every supported platform). The bracketed IPv6 form is covered because
  `parseSeamEndpoint` strips the brackets first. Numeric hosts (and an empty host) throw
  `POSIXError(.EINVAL, description: "SMB over QUIC requires a hostname, not an IP address")`
  before any transport object exists or any network activity occurs. The rule is stated as
  "**non-numeric hostnames only**" (all numeric hosts are rejected) — we do **not** claim
  full syntactic DNS-name/FQDN validation; `localhost`, single-label names, and other
  non-numeric names that later fail resolution are intentionally accepted here and simply fail
  later at resolution. The required rejection table in the `quic-connection-policy` spec is
  **acceptance criteria, not a platform observation**: `getaddrinfo(AI_NUMERICHOST)` is the
  *primary* classifier, and if platform testing shows it fails to classify any required
  representation as numeric on a supported platform, `isNumericHost` is **supplemented with
  deterministic parsing** for that representation (e.g. the legacy `inet_aton` short/hex/octal
  IPv4 grammar, or scoped-IPv6 zone handling) — the requirement is never weakened to match the
  platform. A host is therefore rejected when the platform resolver classifies it as numeric
  *or* the deterministic supplement does; the union is fail-closed and the table always rejects.
  The classifier is an internal
  `static func isNumericHost(_ host: String) -> Bool` so the policy is table-testable with no
  network. Matches Samba/Windows behavior and the project's no-custom-Error convention.
  **Independence from TLS trust policy**: numeric-host rejection runs in the client, before the
  TLS trust policy is applied and before any transport object or `NWConnection` exists. It is
  entirely independent of `SMBQUICConfiguration.trustPolicy`; in particular
  `.insecureNoVerification` — which disables certificate-chain validation and hostname
  verification (D5) — never bypasses or substitutes for numeric rejection. There is **no later
  validation layer** that would reject a numeric target under an insecure trust policy, which
  is exactly why the rejection must be fail-closed here.
- **Port defaulting**: `parseSeamEndpoint` gains the `defaultPort:` parameter described above.
  Explicit ports are honored unchanged.
- **Opt-in**: only `transportKind == .quic` builds the QUIC transport. `.automatic` remains
  `TCPTransportApple` this milestone (re-evaluate after interop maturity).
- **No silent fallback**: QUIC connect errors map through `mapTransportConnectError` and
  propagate; the library never retries over TCP on its own.

Keeping policy in the client (not the conformer) keeps the conformer a pure pipe and makes the
policy unit-testable without any network.

### D5: TLS configuration — platform-neutral, mutually exclusive trust policy

New `SMBQUICConfiguration` (struct, `Sendable`, `Equatable`) — **platform-neutral**: it holds no
Security.framework types, so the type compiles and is public API on every platform including
Linux (where it is inert because `.quic` throws `ENOTSUP`). v1 surface:

```swift
public struct SMBQUICConfiguration: Sendable, Equatable {
    public enum TrustPolicy: Sendable, Equatable {
        case system                      // default: system chain evaluation + hostname verification
        case customRoots([Data])         // DER certificates; non-empty; REPLACE system anchors; hostname still verified
        case insecureNoVerification     // debug-only escape hatch, loudly documented
    }
    public var trustPolicy: TrustPolicy = .system
    public var connectTimeout: TimeInterval = 30    // QUIC connect deadline; see D10 for the contract
    public init(trustPolicy: TrustPolicy = .system, connectTimeout: TimeInterval = 30)
}
```

Trust contract, made explicit:

- **Mutually exclusive by construction**: the enum makes "custom roots + insecure" unrepresentable
  — there is no conflicting-configuration state to reject at runtime. (Alternative — independent
  `trustedRoots` + `allowsInsecureTrust` fields with a runtime `EINVAL` on conflict — rejected:
  an unrepresentable conflict beats a documented one.)
- **`.system` (default)**: no verify block is installed at all; Network.framework's default
  chain evaluation and hostname verification run untouched. TLS 1.3 is QUIC-implied.
- **`.customRoots`**: DER-encoded certificates, converted to `SecCertificate` via
  `SecCertificateCreateWithData` **only inside `QUICTransportApple`** (the Apple boundary). The
  fail-closed sequence is normative and exact:

  1. **Eagerly, before creating the `NWConnection`**: convert every DER value with
     `SecCertificateCreateWithData`. Any invalid DER value — and the degenerate
     `.customRoots([])` (an empty anchor set can never validate anything and is a
     configuration error) — throws `POSIXError(.EINVAL, ...)` before any network activity
     (unit-testable with no network).
  2. In the verify block (`sec_protocol_verify_t`, which receives the connection's
     `sec_trust_t`): obtain the `SecTrust` with `sec_trust_copy_ref(trust_ref)` —
     **not** `sec_protocol_metadata_copy_sec_trust`, which is the wrong accessor for the
     handed-in trust object.
  3. Create the hostname policy with `SecPolicyCreateSSL(true, host)` (server policy with the
     SNI hostname) and apply it with `SecTrustSetPolicies` — custom roots never disable
     hostname checking.
  4. Install the converted anchors with `SecTrustSetAnchorCertificates`, then require only
     those anchors with `SecTrustSetAnchorCertificatesOnly(true)` — anchors **replace** system
     roots, deterministic for the private-CA/self-signed lab case; a chain that validates
     against a system root but not the supplied anchors is rejected. A self-signed *leaf* may
     be supplied as its own anchor (SecTrust accepts an anchor that is the presented
     certificate).
  5. Check **every** `OSStatus` from steps 3–4; any non-`errSecSuccess` status rejects
     verification (complete `false`).
  6. Evaluate with `SecTrustEvaluateWithError`; the boolean result decides verification.
  7. Invoke the verify completion **exactly once on every path** — success, evaluation
     failure, and every `OSStatus` early-out.

  The evaluation core (steps 3–6) is factored into an internal, synchronous helper
  `evaluateCustomRootsTrust(_ trust: SecTrust, host: String, anchors: [SecCertificate]) -> Bool`
  so it is unit-testable against `SecTrust` objects built with
  `SecTrustCreateWithCertificates` — no live handshake needed; the thin verify-block wrapper
  contributes only the `sec_trust_copy_ref` conversion and the exactly-once completion call.
- **`.insecureNoVerification`**: the verify block completes `true` without evaluating the chain
  or the hostname. What remains active: TLS 1.3 encryption, the ALPN `"smb"` requirement, and
  the QUIC handshake itself. What is disabled: certificate-chain validation and hostname
  verification — nothing else. Custom roots and insecure mode cannot be combined (see above).
  It never bypasses the D4 numeric-host rejection, which runs earlier, in the client, before
  any transport or `NWConnection` exists.
- **Security API failures fail closed**: any failure inside the verify block — an `OSStatus`
  from `SecTrustSetPolicies`/`SecTrustSetAnchorCertificates`/
  `SecTrustSetAnchorCertificatesOnly`, or `SecTrustEvaluateWithError` returning `false` —
  completes `false`, failing the handshake.
- **Exactly-once completion**: the verify block is structured so every path — success, policy
  failure, Security API error — calls the verify completion exactly once.
- **No pinning**: certificate/SPKI pinning is not part of this change; `customRoots` is anchor
  replacement, not pinning. Client certs, SPKI pinning, etc. are additive later.

Alternative (expose raw `sec_protocol_options` closure) rejected: too easy to hold wrong, not
testable, ties public API to C SPI shapes. Alternative (`[SecCertificate]` fields) rejected:
cannot compile on Linux, so the configuration type — and with it `SMB2Manager.quicConfiguration`
— would need availability/platform gating across the whole public surface.

### D6: Public API on `SMB2Manager` — snapshot semantics, copying, serialization

`SMB2Manager.transportKind: SMBTransportKind` (var, default `.automatic`) plus optional
`quicConfiguration: SMBQUICConfiguration?` (default `nil` = all defaults). Both are
platform-neutral (D5), so they exist on all platforms with no `#if` on the public surface.
Set-before-connect, like `timeout`.

**Configuration plumbing and snapshot semantics** (the exact path from manager to transport):

1. Backing storage `_transportKind` / `_quicConfiguration` is guarded by the manager's existing
   `connectLock`, accessed only through synchronous accessors (the `needsReconnect`/`setClient`
   pattern — `NSLock` is never touched from async code, per the project's locking rule).
2. At the top of the internal `connect(shareName:encrypted:)` (`AMSMB2.swift:1501`), **before
   any suspension point**, the manager takes an immutable value snapshot under `connectLock` via
   a synchronous helper:
   `private func transportSnapshot() -> (kind: SMBTransportKind, quic: SMBQUICConfiguration?)`.
3. On platforms with `Network` (Apple), the snapshot is passed to
   `SMB2Client.connect(server:share:user:transportKind:quicConfiguration:)` (D4 — that
   signature exists only under `#if canImport(Network)`) and never read again from the manager.
   On platforms without `Network` (Linux), the **manager** routes on the same snapshot (see
   the Linux paragraph below); the configuration-aware client signature does not exist there.
4. `SMB2Client` hands the configuration to `QUICTransportApple(configuration:connectTimeout:)`
   **at construction**; the transport copies the value and never reaches back to the client or
   manager.

Because every hop is a `Sendable` value copy taken before the first `await`, mutating
`transportKind`/`quicConfiguration` *during* a connect attempt cannot race with transport
construction, and mutating them *while connected* never mutates the existing connection — the
new values simply apply to the next `connect(shareName:)` (exactly `timeout`'s semantics; a
reconnect is the caller's decision). This is documented API behavior, with tests.

**NSCopying**: `copy(with:)` (`AMSMB2.swift:236`) currently rebuilds the manager from
url/domain/credential and copies `_workstation`/`timeout`. It MUST additionally copy the value
snapshots of `transportKind` and `quicConfiguration` — otherwise copying a `.quic` manager would
silently revert it to `.automatic`/TCP. Both are value types, so assignment is inherently a
snapshot.

**Serialization**: `SMBTransportKind` has no raw value and we do **not** add a public
`RawRepresentable` conformance — encoding uses a private string mapping
(`"tcp"`/`"quic"`/`"automatic"`) in `NSSecureCoding`/`Codable`, with `.automatic` fallback on
missing/unknown values so old archives keep decoding (no breaking change). `quicConfiguration`
is **not** serialized — deliberately, even though DER `[Data]` *could* be encoded: trust anchors
and the insecure-mode flag are security-sensitive, and honoring them from a persisted archive
would let a stale or tampered archive silently weaken trust; the app must reconstruct the
configuration in code. This covers *all* of `SMBQUICConfiguration`, including `connectTimeout`
(D10). Documented asymmetry: `copy(with:)` preserves `quicConfiguration`
(in-process value copy — including `connectTimeout`), archiving does not (persistence boundary).
Consequence to document: a
decoded manager with `transportKind == .quic` and `quicConfiguration == nil` connects with
system-trust QUIC and the default 30 s connect timeout, which is the safe default.

**Linux (the non-`Network` routing path, concretely)**: the configuration-aware
`SMB2Client.connect(...transportKind:quicConfiguration:)` signature is `#if canImport(Network)`
and does **not** exist on Linux. The routing there is:

- `SMB2Manager.connect(shareName:encrypted:)` takes the **same** immutable transport snapshot
  under `connectLock` before any suspension point — identical snapshot semantics on every
  platform.
- If the snapshot kind is `.quic`, the manager throws `POSIXError(.ENOTSUP)` **before**
  constructing any transport, touching the client connect path, or attempting any network
  activity — never a silent downgrade (the no-silent-fallback rule applies to platforms too).
  Implementation note: `POSIXErrorCode` has no `.ENOTSUP` case on Linux
  (swift-corelibs-foundation), so the rejection bridges the C `ENOTSUP` errno through the numeric
  `POSIXErrorCode(_ code: Int32)` initializer; on Linux that surfaces as the `EOPNOTSUPP` alias
  of `ENOTSUP` (same errno 95), which is the Linux spelling of the same "not supported" result.
- If the snapshot kind is `.tcp` or `.automatic`, the manager invokes the existing legacy
  client connect path (`connect(server:share:user:)`, the libsmb2-owned socket) **unchanged**.
- No QUIC-only type that requires Network or Security frameworks leaks into Linux compilation:
  `QUICTransportApple` and the D7 connect machinery are `#if canImport(Network)`;
  `SMBQUICConfiguration` is platform-neutral by construction (DER `[Data]`, `TimeInterval`).
- Linux tests (run under `make linuxtest`) cover all three kinds: `.quic` → `ENOTSUP` with no
  network attempt; `.tcp` and `.automatic` → legacy path behavior unchanged.

Alternative (parameter on every `connectShare` overload) rejected: touches the whole ObjC compat
surface for no gain.

### D7: `QUICTransportApple.connect` — self-contained one-shot state machine with deadline

The eager transport connect (`bridge.connect` in `connectWithBridge`) completes **before**
libsmb2's cancellation and timeout machinery is installed, so the transport cannot lean on it.
"Mirror `TCPTransportApple`" is also not sufficient — the TCP conformer delegates connect
establishment to NIOTS, while QUIC drives `NWConnection` directly. The binding requirements:

- **Atomic outcome claim — selection AND side effects are one transition**: the connect attempt
  holds an `NSLock`-guarded state (`connecting(continuation)` → `ready` | `failed(cause)`),
  and every completion path funnels through a single internal
  `claimConnectOutcome(_ outcome: ConnectOutcome) -> ClaimedDuty?` that, **under the lock**,
  atomically (a) decides whether this path wins (the state is still `connecting`) and
  (b) takes the continuation and transitions the state. The winner receives back the duty it —
  and only it — must perform *outside* the lock; a loser receives `nil` and performs **no**
  side effects at all. This closes the gap where a one-shot gate protected resumption but not
  side effects (a losing `onCancel` could still `NWConnection.cancel()` a connection that
  `.ready` had just successfully returned):
  - If **`.ready` wins**: the transport transitions to the established state, **retains the
    connection reference for `send`/`receive`** (the reference is *not* cleared on successful
    connect), cancels the deadline timer, and resumes the continuation with success. Any later
    losing path — task cancellation, deadline expiry, `.failed` racing in, `close()` racing the
    claim — observes the claimed state and performs **no cancellation and no destructive
    cleanup**; specifically, a losing `onCancel` never calls `NWConnection.cancel()`. The
    caller's task cancellation is then surfaced by the D12 eager-completion reconciliation in
    `connectWithBridge`: `bridge.connect` returns success while the handoff state is already
    `cancelled` (outcome B), so the reconciliation consumes the cancelled state, closes the
    still-local bridge exactly once (via `close()`, i.e. the D8 local-close path), and throws
    `CancellationError` — the live connection is never destroyed by the losing
    connect-claim path itself, and it never leaks.
  - If **task cancellation, deadline expiry, `.failed`, or `close()` wins** before readiness:
    the winning path — exactly once — cancels the deadline timer, cancels and releases the
    `NWConnection` (clears the stored reference and its `stateUpdateHandler` so no callback
    retains the transport past teardown), and resumes the continuation with the mapped error.
    All other racing paths lose the claim and are side-effect-free no-ops.
- **`NWConnection.stateUpdateHandler`, every state handled explicitly**:
  - `.setup`, `.preparing` — progress; no action.
  - `.waiting(let error)` — **not terminal**: record the error (for diagnostics in a later
    timeout description) and keep waiting; only cancellation or the deadline ends a stuck wait.
  - `.ready` — claim the outcome as success (see the atomic claim above).
  - `.failed(let error)` — claim the outcome as failure with the mapped `POSIXError`; only a
    winning claim cancels the connection.
  - `.cancelled` — terminal teardown acknowledgment; by then the outcome has already been
    claimed by whichever path requested the cancel, so this is a no-op on the claim (defensive
    fallback if no claim exists — `NWConnection` only enters `.cancelled` after our own
    `cancel()` — claim with `POSIXError(.ECONNABORTED)`).
- **Post-ready connection failure is NOT connect completion**: once `.ready` has won the claim,
  the state handler hands over to the established-connection lifecycle (D3/D8), which
  discriminates by **recorded cause**: a `.cancelled` whose local-close cause was recorded by
  `close()` (D8) is the local-close teardown signal — the parked or next `receive()` observes
  empty `Data`, never an error; an unsolicited `.failed`, or a `.cancelled` with **no**
  recorded local-close cause, is abnormal transport loss — the parked or next `receive()`
  throws the mapped `POSIXError`. Neither ever touches the (already consumed) connect claim.
- **Task cancellation**: `connect` wraps the continuation in `withTaskCancellationHandler`;
  `onCancel` calls `claimConnectOutcome(.taskCancelled)` and performs the cancel/release duty
  **only if it wins the claim**; if `.ready` already won, `onCancel` is a side-effect-free
  no-op. Cancellation *before* start is handled by an explicit `try Task.checkCancellation()`
  before the `NWConnection` is created.
- **Deterministic deadline**: a single timer is armed (through the injectable deadline
  scheduler, below) when connect begins, with the validated `connectTimeout` passed at
  construction (sourced from `SMBQUICConfiguration.connectTimeout` per D10 — **independent of
  `SMB2Client.timeout` and of the value later propagated to `smb2_set_timeout`**). On expiry it
  attempts the claim; a winning claim cancels the connection → connect throws
  `POSIXError(.ETIMEDOUT)` (description includes the last `.waiting` error, if any). First of
  ready/failed/cancel/deadline wins via the atomic claim; the timer is cancelled by whichever
  path wins.
- **Error contract**: task cancellation → `CancellationError` (passes through
  `mapTransportConnectError` unchanged); `close()` while connecting →
  `POSIXError(.ECONNABORTED)`; deadline expiry → `POSIXError(.ETIMEDOUT)`; `.failed` →
  `POSIXError` mapped from the `NWError` (POSIX errno preserved where available, otherwise
  `.ECONNREFUSED` with a description) — never a raw Network.framework error.
- **Cleanup is the winner's duty**: the winning claim performs all cleanup exactly once — the
  continuation is consumed inside the claim, the deadline timer is cancelled by the winner, and
  only a *losing-outcome* winner (cancel/deadline/failure/close) cancels the `NWConnection` and
  clears the stored reference and `stateUpdateHandler`. A successful connect keeps the
  connection reference and hands the state machine over to the D3 receive/close shape.

**Deterministic testability — injected seams, no wall-clock, no TEST-NET dependence** (unit
tests must not depend on how the local network stack treats unroutable addresses — routing,
VPNs, and Network.framework may turn a TEST-NET-1 target into an immediate `.failed` instead of
a lingering `.waiting`):

- **Injected connection driver**: the transport talks to `NWConnection` through an internal
  `QUICConnectionDriver` seam (start/cancel + state-event delivery + send/receive primitives).
  The production implementation is a thin `NWConnection` wrapper; tests inject a scripted
  driver via an internal initializer (`QUICTransportApple(configuration:connectTimeout:driver:)`;
  the public path uses the production driver). The test driver can deliver `.waiting`,
  `.ready`, `.failed`, and `.cancelled` deterministically, in any order and interleaving —
  including *post-ready* delivery, so the D8 established-connection lifecycle (local close vs
  unsolicited `.failed`/`.cancelled`) is deterministically testable too.
- **Injected deadline scheduler**: the connect deadline is armed through an internal
  clock/timer seam (`ConnectDeadlineScheduler`: schedule/cancel). The production
  implementation is a `DispatchSourceTimer` on the connection queue; the test implementation
  fires on demand, so deadline expiry is driven without any wall-clock waiting.
- **Cancellation recording**: the test driver records every `cancel()` request, so tests prove
  not only exactly-once continuation completion but also **ownership**: when `.ready` wins a
  race, the losing cancellation/deadline path recorded *no* `cancel()` and the returned
  connection remains usable; when a losing outcome wins, exactly one `cancel()` was recorded.
- TEST-NET-1 endpoints remain only as **optional integration/smoke coverage** (non-gating);
  they are not part of the required deterministic unit suite. See tasks 2.3.
- **Coverage note (as shipped)**: the injected seams make the transport's own behavior fully
  deterministic, but the two Context-level `.quic` *wiring* lines — constructing
  `QUICTransportApple(configuration:connectTimeout:)` under the `#available` gate and handing it
  the validated timeout — are not exercised by a deterministic unit test, because a validated
  non-numeric `.quic` target proceeds to a real `NWConnection` connect (there is no
  transport-factory seam at the `SMB2Client.connect` layer). Both *halves* are independently
  unit-covered — the policy/validation path (`isNumericHost`, `normalizedQUICConnectTimeout`, the
  selector) and the transport behavior (via the D7 seams) — so only the literal construction call
  rests on the interop gate (tasks 4.x). A transport-factory injection point on `SMB2Client`
  could close this if it is ever judged necessary; it was not added to avoid widening the client
  surface for a single construction line.

### D8: Disconnect semantics — best-effort local, honestly scoped (option B)

`TransportBridge` is **unchanged** by this change, and we do not claim guaranteed SMB DISCONNECT
delivery. Today `SMB2Client.disconnect()` (`Context.swift:632`) queues the DISCONNECT PDU and
calls `flushOutboundForSeam`, which only pushes the bytes into the bridge's outbound FIFO; the
immediately following `teardownSeam()` cancels the outbound pump, so the PDU may never reach the
wire. That is the existing, accepted contract for the TCP seam, and QUIC inherits it as-is:

- **Local `disconnect()` is best-effort**: the PDU is queued and flushed into the bridge; wire
  delivery is not guaranteed. SMB sessions are designed to survive this (servers reap sessions);
  the governing issues do not require guaranteed disconnect delivery, so no outbound-drain
  barrier is added. (Option A — a bounded send-completion barrier before QUIC cancellation — was
  considered and rejected as new `TransportBridge` machinery outside this change's scope.)
- The transport distinguishes three teardown shapes, observably identical to
  `TCPTransportApple` — but because local `close()` itself calls `NWConnection.cancel()`
  (which then delivers a `.cancelled` state event), the distinction is implemented as an
  explicit, `NSLock`-guarded **established-connection lifecycle with recorded causes**:
  `ready → localClosing → closed`, or `ready → failed(error)`. Normative semantics:
  - **Local close**: `close()` atomically records the local-close cause (`localClosing`, then
    `closed`) under the lock **before** calling `NWConnection.cancel()`, resumes a parked
    `receive()` with empty `Data` (the bridge teardown signal), and releases resources. The
    `.cancelled` state event that its own `NWConnection.cancel()` subsequently delivers
    observes the recorded cause and is a **no-op acknowledgment** — it is never converted into
    abnormal loss. A parked receiver and any later `receive()` observe empty `Data` after
    local close.
  - **Peer-originated graceful EOF**: the server closes the stream → `receive()` returns empty
    `Data` (final-chunk/stream-EOF delivery on the receive path, not a state event).
  - **Abnormal transport loss**: an unsolicited post-ready `.failed(error)`, or a `.cancelled`
    with **no** recorded local-close cause, transitions `ready → failed(mapped POSIXError)`:
    the parked or next `receive()` throws.
  - **Deterministic race winner**: the first lock-protected transition out of `ready` claims
    the teardown outcome; the parked waiter is resumed **exactly once**; a later `.failed`/
    `.cancelled` event never overwrites an already-recorded local-close result. `close()`
    called after `failed` remains idempotent resource cleanup (subsequent `receive()` then
    returns empty `Data`, matching the close contract) and never resurrects or replaces a
    result already delivered to a waiter.
- Interop verification (task 4.3) accordingly checks *best-effort disconnect + server-side
  session teardown observed*, not "graceful disconnect" as a wire guarantee.

### D9: libsmb2 selector per kind — explicit, not implementation-defined

`smb2_set_transport` selector installed per kind (constants from the fork's `libsmb2.h:286-288`;
`transport_type` only gates built-in-TCP vs external routing, `lib/socket.c:191-202` — no SMB
protocol behavior differs between `AUTO` and `QUIC` once `ext` is installed):

- `.tcp` / `.automatic` → `SMB2_TRANSPORT_AUTO` (== 2) with the bridge's `ext` — **unchanged**
  shipped behavior (the D1-era naming trap: `SMB2_TRANSPORT_TCP` == 0 would select libsmb2's
  built-in socket and ignore `ext`).
- `.quic` → `SMB2_TRANSPORT_QUIC` (== 1) with the bridge's `ext` — behaviorally identical to
  `AUTO`-with-`ext` in the fork today, chosen because it validates `ext` strictly (non-NULL
  callbacks required, no TCP fallback semantics) and records intent in the context.

The selector is passed into `connectWithBridge(selector:)` by the kind dispatch (D4), so the
mapping lives in exactly one `switch`. Linux never reaches this code (`.quic` throws `ENOTSUP`
at the manager boundary, D6; `.tcp`/`.automatic` use the legacy fd path with no
`smb2_set_transport` call).

### D10: QUIC connect timeout — dedicated, finite, always armed

The existing `SMB2Manager.timeout` contract ("set 0 or negative to disable") cannot drive the
QUIC connect deadline: the D7 state machine *requires* a finite, always-armed deadline (a
`.waiting` connection would otherwise hang forever with no libsmb2 machinery installed to
rescue it), and silently re-interpreting `timeout <= 0` for QUIC would change the meaning of an
existing public contract. So the connect deadline gets its own knob:

- **Source**: `SMBQUICConfiguration.connectTimeout: TimeInterval` (public, part of the D5
  struct). `quicConfiguration == nil` means the default configuration, hence the default
  timeout.
- **Default**: 30 seconds. **Valid range**: finite and `> 0`, up to 3600 seconds.
- **Validation and normalization** happen in `SMB2Client.connect`'s hoisted validation step
  (D4), before transport construction and before any network activity, via an internal
  table-testable helper `static func normalizedQUICConnectTimeout(_ value: TimeInterval) throws
  -> TimeInterval`:
  - `NaN`, `+/-infinity`, `0`, and negative values → `POSIXError(.EINVAL)` (fail loud — a
    non-finite or non-positive connect deadline is a configuration error, never "disabled";
    the QUIC connect deadline cannot be disabled).
  - Values greater than 3600 s are clamped to 3600 s (documented; keeps the
    `DispatchSourceTimer` arithmetic trivially safe and bounds a typo'd deadline).
  - Everything else passes through unchanged (sub-second values are honored as-is).
- **Snapshotting**: `connectTimeout` travels inside the `SMBQUICConfiguration` value snapshot
  taken under `connectLock` (D6) — it is independently snapshotted by construction; mutating it
  mid-connect cannot affect the in-flight attempt.
- **Relation to `smb2_set_timeout`**: none — deliberately independent. `SMB2Manager.timeout`
  keeps its exact existing meaning (per-operation timeout; `<= 0` disables) and continues to
  feed `smb2_set_timeout` only when `> 0`, exactly as today. The QUIC connect deadline governs
  only the transport connect phase, which completes before libsmb2's timeout machinery exists.
- **Serialization/copying**: follows the configuration (D6) — `copy(with:)` preserves it;
  archiving omits it (a decoded `.quic` manager gets the 30 s default).
- **Tests**: deterministic boundary tests for `NaN`, `+infinity`, `-infinity`, `0`, negative,
  a sub-second value, `3600` (unclamped), `3601` (clamped to 3600), and the 30 s default —
  all through the pure normalization helper, no network.

Alternative (reuse `SMB2Manager.timeout` with special-casing for `<= 0`) rejected: it either
changes a shipped contract or leaves QUIC with an unarmed deadline; a separate knob is the
smaller, coherent surface.

### D11: Objective-C compatibility — the new surface is intentionally Swift-only

`SMB2Manager` is exported to Objective-C (`@objc(AMSMB2Manager)`), with the ObjC surface built
from *explicitly* `@objc`-annotated members (ObjCCompat.swift; the class is **not**
`@objcMembers`). The new types are not Objective-C-representable: `SMBTransportKind` is a Swift
enum with no raw value, and `SMBQUICConfiguration` is a struct holding an associated-value enum.
Decision — **Swift-only, no bridge**:

- `SMB2Manager.transportKind`, `SMB2Manager.quicConfiguration`, `SMBQUICConfiguration`, and
  `QUICTransportApple` are Swift-only API. Because the class is not `@objcMembers` and the
  members' types are not representable, the compiler cannot infer `@objc` for them — no
  `@nonobjc` annotation is required (and none is added; adding one would imply the member
  *could* otherwise be exposed). The guarantee is verified, not assumed: a compile-level check
  inspects the generated Objective-C interface and asserts the new symbols are absent.
- The existing Objective-C API is untouched and remains source- and binary-compatible: no
  `@objc(...)` selector changes, no new required parameters on any `connectShare` overload
  (the D6 alternative rejecting per-call parameters already locked this in).
- Consequence, documented in API.md: an Objective-C app cannot opt into QUIC directly; it needs
  a small Swift shim that sets `transportKind`/`quicConfiguration`. Acceptable because QUIC is
  a new opt-in feature and the repository's direction is Swift-first; a concrete ObjC bridge
  (e.g. a string-backed `@objc` transport setter) stays additive if ever demanded.

Alternative (ObjC bridge now: `@objc` raw-value enum mirror + an `@objc` configuration class)
rejected: it doubles the public surface and creates a second, divergent way to express trust
policy for a consumer base that has not asked for it.

### D12: `connectWithBridge` bridge-ownership handoff — cancellation-safe from eager connect to seam installation

The eager `bridge.connect` (`Context.swift:1222`) runs **before** the existing
`withTaskCancellationHandler` (`Context.swift:1235`) is installed, and the connected bridge is
only assigned to `transportBridge` (`Context.swift:1299`) inside the `eventLoopQueue` install
block. Without further machinery, a cancellation after the transport reaches `.ready` but
before `smb2_set_transport` leaves a live bridge that neither the transport-level connect
state machine (D7) nor `teardownSeam()` owns. A single `try Task.checkCancellation()` cannot
close this — any check leaves an unprotected gap after it. Normative design:

- **One cancellation scope**: `connectWithBridge` wraps the **entire** interval — from before
  the eager `bridge.connect` through seam installation and the libsmb2 connect — in one outer
  `withTaskCancellationHandler`. The current inner handler (`Context.swift:1235`) is subsumed
  into it; its cleanup behavior is fully defined below for both local and installed ownership.
- **Lock-protected ownership handoff**: an `NSLock`-guarded handoff state records **exactly
  one bridge owner at every instant**:
  `eagerConnecting → localOwned → installing → installed`, plus the terminal states
  `cancelled` (cancellation won the claim; awaiting consumption by the eager-completion
  reconciliation or the install block's failed claim) and `finished` (ownership consumed — by
  the eager-completion reconciliation on a failure or cancellation outcome, or by an
  install-block failure path). Every transition is atomic; the party that wins a transition —
  and only that party — performs the associated close/cleanup duty *outside* the lock (the
  same claim-assigns-duty shape as D7's `claimConnectOutcome`). The bridge therefore closes
  exactly once on every path.
- **Transitions and duties**:
  - **`eagerConnecting`** (before/during `bridge.connect`): `onCancel` transitions
    `eagerConnecting → cancelled` and performs **no close** — the in-flight transport connect
    owns its own teardown, and the bridge-level close duty is assigned later, by the
    eager-completion reconciliation below. Task cancellation propagates into the transport's
    own connect state machine, whose *internal* cancellation error is conformer-specific and
    is **not** relied upon: QUIC's D7 machine throws `CancellationError`, while
    `TCPTransportApple.connect` converts task cancellation to `POSIXError(.ECANCELED)`
    (`TCPTransportApple.swift:169-170`), which `TransportBridge.connect` and
    `mapTransportConnectError` propagate unchanged. A transport whose connect is not
    cancellation-responsive at all simply completes. Every one of these shapes funnels into
    the reconciliation, which alone decides the caller-visible result.
  - **Eager-completion reconciliation** (the connect path, immediately after `bridge.connect`
    returns or throws): one lock-protected transition atomically combines (a) the handoff
    state, (b) whether `bridge.connect` returned success or failure, and (c) whether
    cancellation previously won, and assigns the single cleanup/error duty to the connect
    path. The outcomes:

    | # | Handoff state | `bridge.connect` result | Transition | Close duty | Caller-visible result |
    |---|---|---|---|---|---|
    | A | `eagerConnecting` | success | `eagerConnecting → localOwned` | none | proceed toward installation |
    | B | `cancelled` | success (e.g. QUIC `.ready` won its internal claim after outer cancellation) | `cancelled → finished` (consumed) | connect path calls `bridge.close()` exactly once (→ the transport's D8 local-close path) | throw `CancellationError`; no installation is scheduled and no libsmb2 API is called |
    | C | `cancelled` | failure with a cancellation-shaped error (`CancellationError` or `POSIXError(.ECANCELED)`, e.g. the TCP mapping) | `cancelled → finished` (consumed) | connect path calls `bridge.close()` exactly once — even if the transport already cancelled its underlying channel/connection: `TransportBridge.close()` is the bridge-level ownership release and the underlying transport `close()` is idempotent | **normalize** to `CancellationError` — never propagate the raw `ECANCELED` on a cancellation win; no installation, no libsmb2 call |
    | D | `eagerConnecting` | failure (any error — including a cancellation-shaped error when cancellation did **not** win the handoff) | `eagerConnecting → finished` | connect path calls `bridge.close()` exactly once | rethrow the mapped original transport error (via `mapTransportConnectError`), **not** `CancellationError`; no installation, no libsmb2 call |

    - **E — cancellation racing an ordinary eager failure**: the race is decided by the same
      single lock-protected reconciliation. Precedence rule: cancellation is caller-visible
      **iff** its `eagerConnecting → cancelled` transition committed before the connect path
      takes the reconciliation lock (rows B/C); otherwise the transport failure is
      caller-visible (row D). In every non-A outcome the reconciliation path alone performs
      the single `bridge.close()` — `onCancel` in `eagerConnecting` never closes — so exactly
      one close happens regardless of which side wins, and the precedence is deterministic and
      directly unit-testable by driving the transition table with each commit order.
  - **`localOwned`** (reconciliation outcome A; install block has not claimed): `onCancel`
    transitions `localOwned → cancelled` and **itself closes the still-local bridge exactly
    once** (`TransportBridge.close()` is thread-safe and idempotent, callable from the
    cancellation context). The install block's **first step** inside the serialized
    `eventLoopQueue` block — before any resource is created — is the lock-protected
    `localOwned → installing` claim:
    - **Failed claim** (the state is already `cancelled`): resume the Swift continuation with
      `CancellationError` and return immediately. The failed-claim branch creates **nothing**
      and therefore releases nothing: no `cbPtr` is constructed, `Unmanaged.passRetained(cb)`
      is never called, `makeExternalTransport()` is never called, no `ext.userdata` retain
      exists, and **no libsmb2 API is called** — the already-closed bridge is not touched.
      **Once cancellation has won the handoff claim, no libsmb2 connect work begins.**
    - **Successful claim**: only now does the block construct `cbPtr`
      (`Unmanaged.passRetained(cb)`), perform context validation, and run the
      external-transport installation (`makeExternalTransport()` and its `ext.userdata`
      retain, `smb2_set_transport`, …), creating and balancing resources per the
      failure-path rules below.
  - **`installing`** (install block won the claim): the block runs to `installed`
    (`smb2_set_transport`, `transportBridge = bridge`, `smb2_connect_share_async`,
    continuation registration) as one serialized `eventLoopQueue` block. An `onCancel` that
    finds the state past `localOwned` routes through the installed-ownership path: it marks
    the operation abandoned and enqueues teardown on `eventLoopQueue` (the existing behavior)
    — queue serialization guarantees the install block completes first, so the teardown
    observes `transportBridge` set and `teardownSeam()` closes the installed seam exactly
    once. The install block's own post-registration abandonment re-check
    (`Context.swift:1322`) continues to cover the onCancel-before-continuation-storage
    interleaving, resuming `CancellationError` after `teardownSeam()` exactly as today.
  - **`installed`**: ownership belongs to `transportBridge`/`teardownSeam()`; cancellation and
    timeout behave exactly as the existing seam contract (abandon + `teardownSeam()`;
    idempotent, `transportBridge` nil-ed on first close).
  - **Install-block failure paths** (context gone, `smb2_set_transport` failure,
    `smb2_connect_share_async < 0` — all reachable only *after* a successful `installing`
    claim, since a failed claim returns before anything is created): the block owns the bridge
    (it won `installing`) and performs today's cleanup, releasing **only the resources actually
    created at the point of failure**, in claim-then-create order. The two **pre-install**
    failures — before `transportBridge` is assigned — transition to `finished`, making any late
    `onCancel` a side-effect-free no-op on the bridge: context-gone (checked after the claim and
    `cbPtr` construction) closes the bridge and releases `cbPtr` — no `ext.userdata` retain
    exists yet because `makeExternalTransport()` has not run; `smb2_set_transport` failure
    additionally balances the `ext.userdata` `Unmanaged` retain. The **post-install**
    `smb2_connect_share_async < 0` path runs *after* `transportBridge` is assigned (state
    `installed`), so ownership stays with `transportBridge`/`teardownSeam()` and the state is
    **not** moved to `finished`: it releases `cbPtr` and tears down via `teardownSeam()` (by then
    `transportBridge` is set and libsmb2 owns the `ext.userdata` retain through the C close
    trampoline), and a late `onCancel` routes through the idempotent installed-teardown path
    rather than the bridge no-op.
- **No leaks, provably**: at every instant exactly one party is responsible for closing — the
  eager-completion reconciliation (every cancellation or failure outcome of `bridge.connect`:
  rows B/C/D and the race rule E), `onCancel` (`localOwned`), the install block (`installing`
  failure paths, after its successful claim), or `teardownSeam()` (`installed`). Cancellation
  racing installation has a single lock-protected winner: cancelled-first → local close, no
  libsmb2 call; installed-first → installed-seam teardown — never neither, never both. The
  connect continuation is resumed exactly once (the existing `cb.isAbandoned` machinery is
  unchanged for the installed phase), the `Unmanaged` bridge retain from
  `makeExternalTransport()` is balanced on every not-installed path on which it was created —
  and is never created at all on a failed install claim — and no connected-but-unowned bridge
  or registered libsmb2 operation survives any interleaving.
- **Deterministic testability**: the handoff is factored as an internal lock-protected type
  (transition table in, assigned duty out — mirroring D7's `claimConnectOutcome`) so every
  transition and race above — including all reconciliation rows A–D and both commit orders of
  race E — is unit-tested directly, without real task-cancellation timing.
  MockTransport-backed `connectWithBridge` tests then cover the wired paths:
  - TCP-shaped eager cancellation: the transport fails internally with
    `POSIXError(.ECANCELED)` after cancellation wins, and the caller observes
    `CancellationError` (row C normalization);
  - QUIC-shaped ready-after-cancel: the transport completes successfully despite outer
    cancellation (`.ready` won its internal claim), and the caller observes
    `CancellationError` with the bridge closed (row B);
  - ordinary eager failure (row D): the mapped original transport error surfaces, never
    `CancellationError`;
  - cancellation racing ordinary failure (race E): each commit order yields its documented
    winner deterministically;
  - close-call counting proves the bridge closes **exactly once in every outcome**;
  - after any cancellation or eager-failure win: `transportBridge == nil`, no pending
    operation, no `smb2_set_transport`/`smb2_connect_share_async` call made, and — via a test
    seam or structural assertion — a failed install claim invoked neither the
    callback-pointer factory (`Unmanaged.passRetained(cb)`) nor `makeExternalTransport()`.

Alternative (keep the two-scope structure and add `Task.checkCancellation()` between eager
connect and installation) rejected: every check leaves a gap after it; only an atomic
claim/handoff makes the ownership total. This applies to both conformers — the TCP seam path
gains the same guarantee.

## Interop observations (2026-07-24, live against the standing rig)

First-contact and the full interop matrix were run live (macOS `NWProtocolQUIC` client ↔
Samba 4.23.6 + lxin/quic on `ubuntu-brix.kaveman.intra`). Headline findings:

- **Framing (D2): CONFIRMED.** NEGOTIATE, tree-connect, directory enumeration, and multi-MB
  reads/writes all parse cleanly through libsmb2's direct-transport byte-stream reader over the
  QUIC stream — the 4-byte length prefix is present; no fork-seam frame-stripping is needed. The
  contingency below did not fire.
- **Headline interop finding — Apple ↔ lxin/quic `active_connection_id_limit` incompatibility
  (server-side patch required until upstreamed).** Apple's `NWProtocolQUIC` advertises the QUIC
  transport parameter `active_connection_id_limit = 64`; lxin/quic (through at least HEAD
  `03a9c7c`) rejects any value `> 8` with `-EINVAL`, closing the handshake with
  `CONNECTION_CLOSE(TRANSPORT_PARAMETER_ERROR)` before any ServerHello. This violates
  RFC 9000 §18.2 (the value is the peer's storage willingness; only `< 2` is invalid — larger
  values MUST be accepted). Confirmed by a three-stack discriminator: OpenSSL 3.5.5's QUIC client
  (advertises `2`) and Samba's own client interoperate; Apple (advertises `64`) does not. There is
  **no client-side remedy** (`NWProtocolQUIC` does not expose the parameter). Remediation is a
  one-line RFC-correct clamp in the kernel module (`value > QUIC_CONN_ID_LIMIT` → clamp, not
  reject); with it, first-contact and the full matrix pass. **Fixed upstream 2026-07-25** in
  lxin/quic master `47ca73f` — our PR [lxin/quic#78](https://github.com/lxin/quic/pull/78) for
  issue [#77](https://github.com/lxin/quic/issues/77) (fork `simplekube-ro/quic`, commit
  `08dbf11`). Rigs built from ≥ `47ca73f` need no local patch; this rig was moved to pure upstream
  master on 2026-07-25 and re-verified 14/14 (26 s). See docs/INTEROP-QUIC.md trap #4.
- **No premature idle teardown / keepalive tuning needed.** Multi-MB transfers and interleaved
  connect/op/disconnect cycles complete within `NWProtocolQUIC` defaults; the risk below did not
  materialize.
- **Best-effort disconnect + server-close behavior (D8), observed.** After a best-effort local
  `disconnect()`, the server reaped the session ≈ 2.2 s later (observed via `smbstatus`) — a
  best-effort teardown, not guaranteed DISCONNECT delivery. A server-initiated close mid-session
  surfaces to our client as `POSIXError(.ENOTCONN)` ("SMB2 server not connected") on the next
  operation — prompt and clean, no hang. See docs/INTEROP-QUIC.md.
- **Rig test-infra caveat, resolved (not an SMB/QUIC fault).** The rig originally published QUIC
  via docker's userland UDP proxy (`-p 443:443/udp`), which wedged for new LAN flows under a
  sustained connect/disconnect burst (the whole 14-test suite back-to-back). Switching the rig to
  `--network host` (QUIC binds host UDP/443 directly, no userland proxy) fixed it: the full 14-test
  suite now runs stably in a single 40 s pass. See docs/INTEROP-QUIC.md trap #5.

WS2025 (Microsoft-native MsQuic server) remains the other conformant target, deferred until a
Windows host is available — it may accept Apple's ClientHello where lxin/quic needs the patch.

## Risks / Trade-offs

- [Framing assumption wrong over QUIC] → Verified as first interop gate (D2); contingency is a
  seam-level fix in the libsmb2 fork, transport unchanged. Until interop passes, the feature is
  unreleased-opt-in, so blast radius is zero. **Resolved 2026-07-24: framing confirmed on the
  wire (see Interop observations above); contingency not needed.**
- [No CI-able QUIC server: Samba needs `quic.ko` — no distro kernel ships it (not mainlined as
  of Linux 7.0), and GitHub macOS runners cannot reach a module-capable Linux host] → CI keeps
  MockTransport-based unit coverage. Interop runs against the standing lab rig, verified
  2026-07-24 on `ubuntu-brix.kaveman.intra` (Ubuntu 26.04, kernel 7.0): `quic.ko` built
  out-of-tree from lxin/quic via DKMS (builds against kernels ≥ 6.1; verified on 7.0, newer
  than Samba's tested 6.14), Samba 4.23.6 + libquic in Docker (image `samba-quic:4.23.6`, rig
  in `~/smb-quic-rig/` with README). Samba↔Samba smbclient QUIC transfers verified over the
  published UDP/443 by DNS hostname with lab-CA TLS (tcpdump-confirmed QUIC). Known rig traps,
  documented in the rig README: Samba requires `libquic >= 1.1` but upstream's `.pc` says 1.0
  (build the `samba` branch and patch the installed `.pc`, else configure silently disables
  QUIC); a TLS key not uid-0/0600 makes smbd drop the QUIC listener with only a warning and
  serve TCP; `ss` cannot list `IPPROTO_QUIC` sockets — health-check with a client connect.
  Note the rig verifies the server side only; the D2 must-verify framing gate still runs at
  first contact with our client (task 4.2).
- [`NWProtocolQUIC` behavioral unknowns (idle timeout, keepalive, stream-data limits) under
  long-lived SMB sessions] → Start with system defaults; `maxIdleTimeout`/keepalive only get
  surfaced if interop shows premature idle teardown. The existing timer-driven servicing loop
  already handles libsmb2-side timeouts.
- [Availability split (package floors iOS 13 / macOS 10.15 / macCatalyst 13 vs QUIC floors
  iOS 15 / macOS 12 / macCatalyst 15)] → Runtime `ENOTSUP` + `@available`-gated types; documented
  in API.md; macCatalyst floor verified explicitly (D1). No package-floor bump.
- [watchOS practicality (background/network constraints)] → Compiles and is gated; not an
  interop target for v1.
- [Users expecting auto-fallback like Windows' TCP-then-QUIC] → Explicit-opt-in is a deliberate
  #346 requirement; README documents the caller-side fallback pattern (try `.quic`, catch,
  retry `.tcp`).

## Migration Plan

Purely additive; no breaking changes; ships on the 5.99.x runway. Rollout: implement + unit
tests → manual interop gate against Samba 4.23+ (and WS2025 when available) → docs → release.
Rollback = don't set `.quic` (default path untouched). RandomPlayer #347 adopts afterwards.

## Open Questions

- ~~Exact `quic.ko` interop rig (Lima VM with mainline 6.14 kernel vs. cloud WS2025 instance)~~ —
  **resolved 2026-07-24**: external Ubuntu 26.04 box (`ubuntu-brix.kaveman.intra`) with DKMS
  `quic.ko` and Samba 4.23.6 in Docker, stood up and verified Samba↔Samba (see Risks).
  WS2025 deferred until a Windows target is available.
- Whether `.automatic` should ever try QUIC (e.g. after a successful QUIC connection is cached)
  — deferred; revisit post-interop with RandomPlayer #347 experience.
- NTLM-over-QUIC vs Kerberos: libsmb2 does NTLMSSP; WS2025 workgroup/NTLM path is the realistic
  first Windows interop case (matches Microsoft's workgroup guidance). No code impact expected.
