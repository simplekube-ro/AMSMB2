# Proposal: add-quic-transport

## Why

The pluggable-transport milestone (RandomPlayer #344/#345, AMSMB2 #28) landed the `SMBTransport` seam and flipped Apple platforms onto it, but `SMBTransportKind.quic` is still a reserved case that throws `ENOTSUP` (`Context.swift:1128`). SMB-over-QUIC (UDP/443, TLS 1.3) is the core feature of the current milestone (AMSMB2 #29, RandomPlayer #346): it lets the client reach Windows Server 2025 / Samba 4.23+ file servers over untrusted networks where TCP/445 is blocked, and it unblocks RandomPlayer #347.

## What Changes

- Add `QUICTransportApple`, a new `SMBTransport` conformer backed by Network.framework QUIC (`NWProtocolQUIC`) — system QUIC, nothing to ship, App-Store-safe. Availability-gated (`@available(iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1, *)`); older OS versions fail with `ENOTSUP`.
- Wire mapping follows the Microsoft/Samba interop behavior (verified against Samba's client implementation, `source3/libsmb/smbsock_connect.c`): ALPN token `"smb"`, TLS 1.3, one QUIC connection with a **single bidirectional stream used as a byte pipe**. The stream carries the exact same framed SMB2 byte stream as direct TCP (4-byte transport length prefix included) — libsmb2 keeps doing all SMB framing/auth inside the tunnel; the transport stays a dumb pipe, same as `TCPTransportApple`.
- Connection policy (per #346 — "don't get these wrong"):
  - QUIC is **explicit opt-in** — never auto-selected; `.automatic` continues to mean TCP.
  - **Name-based hosts only** — raw IPv4/IPv6 targets are rejected (mirrors Samba/Windows client behavior).
  - Default port **UDP/443** when the server string has no explicit port (TCP keeps 445).
  - No silent TCP fallback: a QUIC connect failure surfaces as an error; falling back is the caller's decision.
- TLS security surface: system trust evaluation and hostname verification by default — **never insecure by default**. Any relaxation (custom trust roots, pinned/self-signed server certificate) is an explicit opt-in configuration.
- Public API: `SMB2Manager` gains transport selection (today `connect(shareName:encrypted:)` hardcodes `.automatic`, `AMSMB2.swift:1511`) plus the QUIC TLS options type. `SMB2Client.connect(transportKind:)` constructs `QUICTransportApple` for `.quic` instead of throwing.
- Tests: unit tests for policy (IP rejection, port defaulting, opt-in dispatch, availability gating) and transport behavior; integration/interop plan against Samba 4.23+ (`server smb transports = +quic`) and/or Windows Server 2025 — the Docker story is constrained by the `quic.ko` kernel-module requirement, so interop may start as a documented manual procedure.

## Capabilities

### New Capabilities

- `quic-transport-apple`: The `NWProtocolQUIC`-backed `SMBTransport` conformer — connect/handshake (ALPN `"smb"`, TLS 1.3, SNI), single-bidirectional-stream byte-pipe send/receive, graceful-EOF and error mapping to `POSIXError`, close/cancellation semantics, availability gating.
- `quic-connection-policy`: The rules governing when and how QUIC is used — explicit opt-in selection, name-based-host enforcement (raw-IP rejection), UDP/443 port defaulting, no-silent-fallback, and the secure-by-default TLS configuration surface with explicit opt-in overrides.

### Modified Capabilities

- `transport-seam`: `SMBTransportKind.quic` changes from "reserved for a future milestone" to an implemented kind; the kind-dispatch requirement now builds a QUIC transport instead of throwing `ENOTSUP`.
- `transport-servicing`: Seam endpoint handling becomes transport-aware — the default port is 443 for `.quic` (445 for TCP); kind dispatch constructs `QUICTransportApple`.
- `api-reference`: Document the new public API surface (transport selection on `SMB2Manager`, QUIC TLS options, availability constraints) in `docs/API.md`.

## Impact

- **New code**: `AMSMB2/QUICTransportApple.swift` (+ a QUIC TLS options type). No new package dependencies — Network.framework only (explicitly not `swift-nio-quic`, MsQuic, ngtcp2, or quiche per #346).
- **Changed code**: `Context.swift` (kind dispatch at :1124–1130, per-kind default port in `parseSeamEndpoint`), `AMSMB2.swift` (public transport selection, NSSecureCoding/Codable of the new setting), `SMBTransport.swift` (doc comment for `.quic`), `docs/API.md`, `docs/ARCHITECTURE.md`, README.
- **Unchanged**: the libsmb2 fork (the external-transport C seam and `smb2_get_timeout`/`smb2_service_timeout` timer hooks from the TCP milestone already provide everything QUIC needs), `TransportBridge`, the servicing loop, all SMB semantics (auth, signing, encryption happen inside the tunnel).
- **Platform**: QUIC path is Apple-only in this change (`#if canImport(Network)`), matching the seam itself; Linux keeps the legacy socket path. Runtime OS floor for QUIC is higher than the package floor — handled by availability gating, not by raising package minimums.
- **Testing infra**: Samba 4.23+ QUIC server needs the `quic.ko` kernel module (~Linux 6.14) — not viable in Docker-on-macOS CI today; interop testing lands as a documented, repeatable manual procedure plus whatever CI automation proves feasible.
- **Downstream**: unblocks RandomPlayer #347 (adopt pluggable transports in RandomPlayer).
