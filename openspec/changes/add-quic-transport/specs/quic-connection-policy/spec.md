# quic-connection-policy Specification

## ADDED Requirements

### Requirement: QUIC is explicit opt-in only

The library SHALL use the QUIC transport only when the caller explicitly selects
`SMBTransportKind.quic`. `.automatic` SHALL continue to select TCP, and the library SHALL NOT
switch to QUIC based on port number, server capability, or any other heuristic.

#### Scenario: automatic never selects QUIC

- **WHEN** a connection is opened with `.automatic` (including to a server on port 443)
- **THEN** the TCP transport is used

#### Scenario: quic selects the QUIC transport

- **WHEN** a connection is opened with `.quic` on a supported OS version
- **THEN** `QUICTransportApple` is constructed and used for the connection

#### Scenario: quic on an unsupported OS version (manual verification)

- **WHEN** `.quic` is selected on an OS older than the QUIC availability floor
- **THEN** connect throws `POSIXError(.ENOTSUP)`
- **NOTE** CI hosts always satisfy the floor, so the `#unavailable` branch is unreachable in
  unit tests; verified by code inspection (same pattern as the transport-servicing "Deferred to
  T8" notes)

#### Scenario: quic on Linux

- **WHEN** `.quic` is selected on a platform without `Network` (Linux)
- **THEN** connect throws `POSIXError(.ENOTSUP)` — never a silent downgrade to the legacy TCP
  path (`.tcp`/`.automatic` continue to use the legacy libsmb2 socket path on Linux)

### Requirement: QUIC targets must be DNS names, not IP addresses

When `.quic` is selected, the client SHALL reject a target host that is a raw IPv4 or IPv6
literal (including the bracketed `[...]` form) with `POSIXError(.EINVAL)` and a descriptive
message, before any network activity. This mirrors the Samba and Windows SMB-over-QUIC client
behavior.

#### Scenario: IPv4 literal rejected

- **WHEN** connecting with `.quic` to `192.168.1.10`
- **THEN** connect throws `POSIXError(.EINVAL)` and no connection attempt is made

#### Scenario: IPv6 literal rejected

- **WHEN** connecting with `.quic` to `[fe80::1]`
- **THEN** connect throws `POSIXError(.EINVAL)` and no connection attempt is made

#### Scenario: DNS name accepted

- **WHEN** connecting with `.quic` to `fs.example.com`
- **THEN** host validation passes and the QUIC connect proceeds

#### Scenario: TCP is unaffected

- **WHEN** connecting with `.tcp` or `.automatic` to an IP literal
- **THEN** the connection proceeds exactly as before this change

### Requirement: QUIC default port is UDP 443

When `.quic` is selected and the server string carries no explicit port, the client SHALL
default to port 443. An explicit port in the server string SHALL be honored unchanged. TCP
default remains 445.

#### Scenario: Default port

- **WHEN** connecting with `.quic` to `fs.example.com`
- **THEN** the transport connects to UDP port 443

#### Scenario: Explicit port honored

- **WHEN** connecting with `.quic` to `fs.example.com:8443`
- **THEN** the transport connects to UDP port 8443

### Requirement: No silent transport fallback

When a `.quic` connection attempt fails, the library SHALL surface the error to the caller and
SHALL NOT retry over TCP (or any other transport) on its own. Fallback is the caller's decision.

#### Scenario: QUIC failure propagates

- **WHEN** a `.quic` connect fails (handshake failure, timeout, refused)
- **THEN** the error is thrown to the caller and no TCP connection is attempted

### Requirement: SMB2Manager exposes transport selection

`SMB2Manager` SHALL expose a `transportKind: SMBTransportKind` property (default `.automatic`)
and an optional `quicConfiguration: SMBQUICConfiguration?`, both consulted at connect time.
The transport kind SHALL round-trip through `NSSecureCoding`/`Codable` with `.automatic` as the
decode fallback so existing archives keep decoding; `quicConfiguration` SHALL NOT be serialized.

#### Scenario: Default behavior unchanged

- **WHEN** an existing consumer uses `SMB2Manager` without touching the new properties
- **THEN** connections behave exactly as before this change

#### Scenario: Manager-level QUIC opt-in

- **WHEN** `transportKind = .quic` is set before `connectShare`
- **THEN** the underlying client connects using the QUIC transport and policy

#### Scenario: Old archives decode

- **WHEN** an `SMB2Manager` archive created before this change is decoded
- **THEN** decoding succeeds and `transportKind` is `.automatic`
