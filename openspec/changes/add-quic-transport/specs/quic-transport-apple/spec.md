# quic-transport-apple Specification

## ADDED Requirements

### Requirement: QUICTransportApple implements SMBTransport over Network.framework QUIC

The library SHALL provide a public `QUICTransportApple` class conforming to `SMBTransport`,
backed directly by `NWConnection` with `NWProtocolQUIC` (no NIO, no third-party QUIC stack),
compiled only where `Network` is available and availability-gated to
iOS 15 / macOS 12 / tvOS 15 / watchOS 8 / visionOS 1 or later.

#### Scenario: Conformer is a pure byte pipe

- **WHEN** libsmb2 hands the seam an outbound framed SMB2 byte sequence and `send(_:)` is called
- **THEN** the bytes are written to the QUIC stream verbatim, with no SMB-aware inspection,
  reframing, or modification

#### Scenario: Availability gating

- **WHEN** the library is built for a deployment target older than the QUIC availability floor
- **THEN** the package still compiles (package platform minimums are unchanged) and
  `QUICTransportApple` is only usable behind an `@available` check

### Requirement: QUIC handshake uses ALPN "smb", TLS 1.3, and SNI

`connect(host:port:)` SHALL establish a QUIC connection whose TLS 1.3 handshake advertises
exactly the ALPN token `"smb"` and sets the TLS server name (SNI) to the target host name, per
the Microsoft/Samba SMB-over-QUIC interop behavior.

#### Scenario: Handshake parameters (interop-verified)

- **WHEN** `connect(host:port:)` is called
- **THEN** the QUIC security options carry ALPN `"smb"` and SNI equal to `host`
- **AND** the connection targets UDP `port`
- **NOTE** verified by code inspection plus the manual interop gate (tasks 4.2) — the live
  handshake cannot run in unit tests

#### Scenario: Handshake failure maps to POSIXError

- **WHEN** the QUIC/TLS handshake fails (unreachable host, ALPN rejection, TLS failure)
- **THEN** `connect` throws a `POSIXError` (never a raw Network.framework error), preserving
  `CancellationError` when the task was cancelled

### Requirement: Single bidirectional stream carries the SMB session

The transport SHALL use one QUIC connection with a single bidirectional stream for the entire
SMB session. It SHALL NOT create per-request streams; SMB2 request multiplexing continues inside
the single stream exactly as over TCP.

#### Scenario: All traffic on one stream

- **WHEN** multiple SMB2 requests are in flight concurrently
- **THEN** all outbound and inbound bytes flow over the same bidirectional QUIC stream

### Requirement: receive honors the seam's chunk and EOF conventions

`receive()` SHALL return the next available inbound chunk as `Data`, buffering incrementally
when data arrives faster than it is consumed, and SHALL return empty `Data` exactly when the
peer closes the stream gracefully. Abnormal connection loss SHALL throw a `POSIXError`.

#### Scenario: Graceful EOF

- **WHEN** the server closes the QUIC stream/connection gracefully
- **THEN** a pending or subsequent `receive()` returns empty `Data`

#### Scenario: Abnormal loss

- **WHEN** the QUIC connection fails (network loss, reset)
- **THEN** a pending or subsequent `receive()` throws a `POSIXError`

### Requirement: close is idempotent and releases resources

`close()` SHALL cancel the QUIC connection, resume any parked `receive()` waiter with empty
`Data` (graceful EOF — matching `TCPTransportApple` so the `TransportBridge` sees the identical
teardown signal on both conformers), release all resources, and SHALL be safe to call multiple
times and concurrently with in-flight operations. `receive()` after `close()` SHALL return
empty `Data`; `POSIXError(.ENOTCONN)` is reserved for `receive()`/`send(_:)` on a
never-connected transport.

#### Scenario: Close with a parked receiver

- **WHEN** `close()` is called while a `receive()` continuation is parked
- **THEN** the parked call completes with empty `Data` (graceful EOF) and no continuation leaks

#### Scenario: Receive after close

- **WHEN** `receive()` is called after `close()`
- **THEN** it returns empty `Data` without throwing

#### Scenario: Never connected

- **WHEN** `receive()` is called on a transport that was never connected
- **THEN** it throws `POSIXError(.ENOTCONN)`

#### Scenario: Double close

- **WHEN** `close()` is called twice
- **THEN** the second call is a no-op and no crash or double-release occurs

### Requirement: TLS trust is secure by default with explicit opt-in overrides

The transport SHALL use system certificate-chain evaluation and hostname verification by
default. A public `SMBQUICConfiguration` type SHALL allow explicit opt-in overrides (custom
trusted roots; an insecure-trust escape hatch that defaults to off). The library SHALL NOT
install any custom verify logic unless the caller explicitly set an override.

#### Scenario: Default trust rejects invalid certificates

- **WHEN** the server presents a certificate that fails system trust or hostname verification
  and no override was configured
- **THEN** the handshake fails and `connect` throws

#### Scenario: Custom roots opt-in

- **WHEN** the caller sets `trustedRoots` in `SMBQUICConfiguration`
- **THEN** chain evaluation anchors to those roots (hostname verification still enforced)

#### Scenario: Insecure trust is never the default

- **WHEN** an `SMBQUICConfiguration` is created without arguments
- **THEN** `allowsInsecureTrust` is `false` and system verification applies
