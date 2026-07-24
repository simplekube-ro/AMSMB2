# api-reference Delta Specification

## MODIFIED Requirements

### Requirement: All public types documented

The API reference SHALL document every public type: `SMB2Manager`, `SMB2Client`, `SMB2FileHandle`, `AsyncInputStream`, `SMB2FileChangeType`, `SMB2FileChangeAction`, `SMB2FileChangeInfo`, `SMBTransport`, `SMBTransportKind`, `TCPTransportApple`, `QUICTransportApple`, and `SMBQUICConfiguration`. For the transport seam types, the reference SHALL document that transport selection is exposed through `SMB2Manager.transportKind` (default `.automatic` → TCP), the QUIC availability floor on every Apple platform (iOS 15 / macOS 12 / macCatalyst 15 / tvOS 15 / watchOS 8 / visionOS 1) and the Linux behavior (`.quic` → `ENOTSUP`; configuration types exist but are inert), and the QUIC connection policy (explicit opt-in, all numeric hosts rejected — non-numeric hostnames only, so `localhost` and single-label names are accepted even though they may later fail resolution; rejection precedes and is independent of the TLS trust policy, and `.insecureNoVerification` does not bypass it — UDP/443 default, no silent fallback, secure-by-default TLS with the mutually exclusive `TrustPolicy`, and the dedicated `SMBQUICConfiguration.connectTimeout` — default 30 s, finite positive values only with `EINVAL` on `NaN`/infinite/zero/negative and clamping above 3600 s, independent of `SMB2Manager.timeout`'s zero-or-negative-disables contract). The reference SHALL also document the settings' snapshot semantics (changes never affect an in-flight or established connection), that `copy()` preserves `transportKind` and `quicConfiguration` while archiving round-trips only `transportKind`, that the new transport/configuration surface is Swift-only and intentionally absent from the Objective-C interface while the existing Objective-C API is unchanged (design D11), and that local disconnect is best-effort (the DISCONNECT PDU's wire delivery is not guaranteed).

#### Scenario: Type lookup
- **WHEN** a developer or AI agent searches for a type name in the API reference
- **THEN** they SHALL find its purpose, conformances, and key properties

#### Scenario: Transport seam types are documented
- **WHEN** a developer looks up `SMBTransport`, `SMBTransportKind`, `TCPTransportApple`, `QUICTransportApple`, or `SMBQUICConfiguration`
- **THEN** they SHALL find the protocol surface (`connect`/`send`/`receive`/`close`), the `.tcp`/`.quic`/`.automatic` cases and their selection semantics, the transport's Apple-only constraint and per-platform availability floors (including macCatalyst 15), the platform-neutral `SMBQUICConfiguration.TrustPolicy` cases (`.system`/`.customRoots`/`.insecureNoVerification`, DER `[Data]` anchors, roots replace system anchors, hostname verification always on except insecure mode), and how to opt into QUIC via `SMB2Manager.transportKind` and `quicConfiguration`

#### Scenario: QUIC policy and errors are documented
- **WHEN** a developer looks up SMB-over-QUIC usage
- **THEN** they SHALL find the error conditions (`EINVAL` for numeric-host targets, invalid DER anchors, an empty `.customRoots([])` anchor set, and invalid `connectTimeout` values; `ENOTSUP` below the availability floor or on Linux; `ETIMEDOUT` for the `connectTimeout` connect deadline; `ECONNABORTED` for close-during-connect; `CancellationError` for task cancellation), the secure-by-default TLS trust policy with explicit opt-in cases, and the caller-side TCP-fallback pattern

### Requirement: Error documentation

The API reference SHALL document common error conditions (POSIXError codes) for operations that throw, including: ENOTCONN (not connected), ENOENT (path not found), EEXIST (already exists), EACCES (permission denied), ECONNREFUSED (transport connect refused), ETIMEDOUT (QUIC connect deadline — `SMBQUICConfiguration.connectTimeout` — expired), ECONNABORTED (transport closed while connecting), ENOTSUP (unsupported — selecting `.quic` below the QUIC availability floor or on a platform without `Network`, e.g. Linux), and EINVAL (invalid argument — including a numeric target host, an invalid DER trust anchor or empty `.customRoots([])` anchor set, or a `NaN`/infinite/non-positive `connectTimeout` with `.quic`). The reference SHALL note that the tabulated numeric values are Darwin `errno` codes and that Linux assigns different numbers to the same symbols.

#### Scenario: Error handling guidance
- **WHEN** a developer catches an error from an AMSMB2 operation
- **THEN** they SHALL be able to look up the error code in the API reference to understand its meaning
