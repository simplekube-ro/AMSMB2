# api-reference Delta Specification

## MODIFIED Requirements

### Requirement: All public types documented

The API reference SHALL document every public type: `SMB2Manager`, `SMB2Client`, `SMB2FileHandle`, `AsyncInputStream`, `SMB2FileChangeType`, `SMB2FileChangeAction`, `SMB2FileChangeInfo`, `SMBTransport`, `SMBTransportKind`, `TCPTransportApple`, `QUICTransportApple`, and `SMBQUICConfiguration`. For the transport seam types, the reference SHALL document that transport selection is exposed through `SMB2Manager.transportKind` (default `.automatic` → TCP), the QUIC availability floor (iOS 15 / macOS 12 / tvOS 15 / watchOS 8 / visionOS 1), and the QUIC connection policy (explicit opt-in, DNS-name-only targets, UDP/443 default, no silent fallback, secure-by-default TLS).

#### Scenario: Type lookup
- **WHEN** a developer or AI agent searches for a type name in the API reference
- **THEN** they SHALL find its purpose, conformances, and key properties

#### Scenario: Transport seam types are documented
- **WHEN** a developer looks up `SMBTransport`, `SMBTransportKind`, `TCPTransportApple`, `QUICTransportApple`, or `SMBQUICConfiguration`
- **THEN** they SHALL find the protocol surface (`connect`/`send`/`receive`/`close`), the `.tcp`/`.quic`/`.automatic` cases and their selection semantics, the Apple-only constraint and availability floors, and how to opt into QUIC via `SMB2Manager.transportKind` and `quicConfiguration`

#### Scenario: QUIC policy and errors are documented
- **WHEN** a developer looks up SMB-over-QUIC usage
- **THEN** they SHALL find the error conditions (`EINVAL` for IP-literal targets, `ENOTSUP` below the availability floor), the secure-by-default TLS behavior with explicit opt-in overrides, and the caller-side TCP-fallback pattern

### Requirement: Error documentation

The API reference SHALL document common error conditions (POSIXError codes) for operations that throw, including: ENOTCONN (not connected), ENOENT (path not found), EEXIST (already exists), EACCES (permission denied), ECONNREFUSED (transport connect refused), ENOTSUP (unsupported — selecting `.quic` below the QUIC availability floor or on a platform without `Network`, e.g. Linux), and EINVAL (invalid argument — including a raw-IP target host with `.quic`). The reference SHALL note that the tabulated numeric values are Darwin `errno` codes and that Linux assigns different numbers to the same symbols.

#### Scenario: Error handling guidance
- **WHEN** a developer catches an error from an AMSMB2 operation
- **THEN** they SHALL be able to look up the error code in the API reference to understand its meaning
