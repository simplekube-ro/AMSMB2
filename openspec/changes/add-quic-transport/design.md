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

Consequence: availability floor is `@available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *)`
— higher than the package floor (iOS 13/macOS 10.15). The class and the `.quic` dispatch arm are
availability-gated; on older OSes `.quic` fails with `POSIXError(.ENOTSUP)` at runtime (the
package floor does not change).

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
= graceful EOF; close is idempotent and resumes the parked waiter with **empty `Data`** —
graceful EOF, exactly like `TCPTransportApple.close()` → `signalClosed()`,
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
  parsing. The kind-aware `connect(server:share:user:transportKind:)` therefore hoists the
  endpoint work: it calls `parseSeamEndpoint(server, defaultPort:)` (445 for TCP kinds, 443 for
  `.quic`), runs host validation, and only then constructs the transport and bridge.
  `connectWithBridge` changes signature to accept the already-resolved `(host, port)` (plus the
  original `server` string for libsmb2), so parsing happens exactly once and validation precedes
  both transport construction and `bridge.connect()` (the eager-connect ordering).
- **Raw-IP rejection**: during that hoisted validation, `.quic` checks the host with
  `inet_pton(AF_INET/AF_INET6)`; a literal (including the bracketed IPv6 form) throws
  `POSIXError(.EINVAL, description: "SMB over QUIC requires a DNS name, not an IP address")`
  before any transport object exists or any network activity occurs. Matches Samba/Windows
  behavior and the project's no-custom-Error convention.
- **Port defaulting**: `parseSeamEndpoint` gains the `defaultPort:` parameter described above.
  Explicit ports are honored unchanged.
- **Opt-in**: only `transportKind == .quic` builds the QUIC transport. `.automatic` remains
  `TCPTransportApple` this milestone (re-evaluate after interop maturity).
- **No silent fallback**: QUIC connect errors map through `mapTransportConnectError` and
  propagate; the library never retries over TCP on its own.

Keeping policy in the client (not the conformer) keeps the conformer a pure pipe and makes the
policy unit-testable without any network.

### D5: TLS configuration — minimal, secure-by-default options type

New `SMBQUICConfiguration` (struct, `Sendable`): v1 surface is deliberately tiny —
`trustedRoots: [SecCertificate]` (empty = system trust) and
`allowsInsecureTrust: Bool` (default `false`, debug-only escape hatch, loudly documented).
Defaults: system trust evaluation, hostname verification against SNI, TLS 1.3 (QUIC-implied).
Overrides are implemented with `sec_protocol_options_set_verify_block` **only when** the caller
explicitly set one of the opt-in fields; otherwise no verify block is installed and the system
default path runs. Client certs, pinning-by-SPKI, etc. are additive later. Alternative (expose
raw `sec_protocol_options` closure) rejected: too easy to hold wrong, not testable, ties public
API to C SPI shapes.

### D6: Public API on `SMB2Manager`

`SMB2Manager.transportKind: SMBTransportKind` (var, default `.automatic`) plus optional
`quicConfiguration: SMBQUICConfiguration?`, both consulted by the internal
`connect(shareName:encrypted:)`. Set-before-connect, like `timeout`. Serialization:
`SMBTransportKind` has no raw value and we do **not** add a public `RawRepresentable`
conformance — encoding uses a private string mapping (`"tcp"`/`"quic"`/`"automatic"`) in
`NSSecureCoding`/`Codable`, with `.automatic` fallback on missing/unknown values so old
archives keep decoding (no breaking change). `quicConfiguration` is **not** serialized (holds
`SecCertificate`s; reconstructed by the app) — consequence to document: a decoded manager with
`transportKind == .quic` and `quicConfiguration == nil` connects with system-trust QUIC, which
is the safe default. **Linux**: the properties exist on all platforms (no `#if` on the public
surface), but the Linux connect path honors them explicitly — `.tcp`/`.automatic` use the
legacy libsmb2 socket path as today, and `.quic` throws `POSIXError(.ENOTSUP)` rather than
silently downgrading (the no-silent-fallback rule applies to platforms too). Alternative
(parameter on every `connectShare` overload) rejected: touches the whole ObjC compat surface
for no gain.

## Risks / Trade-offs

- [Framing assumption wrong over QUIC] → Verified as first interop gate (D2); contingency is a
  seam-level fix in the libsmb2 fork, transport unchanged. Until interop passes, the feature is
  unreleased-opt-in, so blast radius is zero.
- [No CI-able QUIC server: Samba needs `quic.ko` (~6.14 kernel) — Docker Desktop's LinuxKit VM
  can't load it] → Interop is a documented manual procedure (Lima/UTM VM with a 6.14+ kernel, or
  a WS2025 target); CI keeps MockTransport-based unit coverage. Tracked as an explicit task, not
  silently dropped.
- [`NWProtocolQUIC` behavioral unknowns (idle timeout, keepalive, stream-data limits) under
  long-lived SMB sessions] → Start with system defaults; `maxIdleTimeout`/keepalive only get
  surfaced if interop shows premature idle teardown. The existing timer-driven servicing loop
  already handles libsmb2-side timeouts.
- [Availability split (package floor iOS 13 vs QUIC floor iOS 15)] → Runtime `ENOTSUP` +
  `@available`-gated types; documented in API.md. No package-floor bump.
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

- Exact `quic.ko` interop rig (Lima VM with mainline 6.14 kernel vs. cloud WS2025 instance) —
  resolved during the interop task; does not block implementation.
- Whether `.automatic` should ever try QUIC (e.g. after a successful QUIC connection is cached)
  — deferred; revisit post-interop with RandomPlayer #347 experience.
- NTLM-over-QUIC vs Kerberos: libsmb2 does NTLMSSP; WS2025 workgroup/NTLM path is the realistic
  first Windows interop case (matches Microsoft's workgroup guidance). No code impact expected.
