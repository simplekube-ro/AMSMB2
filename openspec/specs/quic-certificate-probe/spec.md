# quic-certificate-probe Specification

## Purpose
Lets a consumer retrieve the certificate chain an SMB-over-QUIC server presents — without
trusting it and without creating an SMB session — so the app can implement trust-on-first-use
(show subject / SAN / validity / fingerprint, let the user confirm, persist the DER as the
`.customRoots` anchor) on top of the library's own QUIC wire contract.

## Requirements

### Requirement: Probe returns the presented chain without ever trusting the peer

The library SHALL expose a public, Swift-only, platform-neutral entry point
`SMBQUICCertificateProbe.fetchServerCertificateChain(server:timeout:) async throws -> [Data]`
that performs exactly one SMB-over-QUIC TLS handshake (ALPN `"smb"`, SNI = host, TLS 1.3)
against the target and returns the DER-encoded certificate chain the server presented,
**leaf first**. The verify step SHALL capture the chain and then SHALL always reject the
handshake — no code path SHALL complete verification successfully — so the connection is torn
down before any application data is exchanged. No SMB PDU SHALL ever be sent and no SMB
session or `SMB2Context` SHALL be created. The server's own rejection of the handshake after the
capture is the expected outcome and SHALL NOT be reported as an error. Security.framework types
SHALL NOT appear in the public signature; the chain is `[Data]`. The capture-only verify mode
is internal and SHALL be unreachable from any public configuration — `SMBQUICConfiguration`
and its `TrustPolicy` cases are unchanged, and a consumer cannot connect with it.

**NOTE (verification):** the production verify-block wiring (`sec_trust_t` → captured chain →
reject) cannot be exercised in a unit test because `sec_trust_t` is not constructible there; it
is verified by code inspection plus the interop-verified scenarios below. The `SecTrust → [Data]`
conversion and the capture slot are unit-tested.

#### Scenario: Self-signed server yields its leaf (interop-verified)
- **WHEN** the probe targets a server whose certificate is a self-signed leaf (Windows Server
  2022 interop target)
- **THEN** it returns exactly one `Data` whose SHA-256 equals the SHA-256 of the server's
  exported `.cer`, and supplying that `Data` as `.customRoots([der])` to a subsequent
  `.quic` connect succeeds

#### Scenario: Private-CA server yields leaf then intermediates (interop-verified)
- **WHEN** the probe targets a server whose certificate chains to a private CA
- **THEN** it returns the leaf first followed by any intermediate certificates the server sent,
  and `.customRoots` built from the returned material connects

#### Scenario: Chain captured, handshake rejected after capture
- **WHEN** the verify step has captured a chain and the transport then reports the handshake as
  rejected for a TLS reason
- **THEN** the probe returns the captured chain and does not throw

#### Scenario: Server unexpectedly accepts
- **WHEN** the connection reports ready even though verification was rejected (a
  defensive case that must not leave a trusted-but-unauthenticated connection alive)
- **THEN** the probe tears the connection down and returns the captured chain; if no chain was
  captured it throws `POSIXError(.EPROTO)`

### Requirement: Probe applies the QUIC connect validation and timeout contract

`server` SHALL accept the same `host[:port]` string as `SMB2Manager` for `.quic`: an explicit
port is honored, otherwise UDP/443. Before any network activity the probe SHALL reject a
numeric or empty host with `POSIXError(.EINVAL)` (same classifier as `.quic` connect, so the
two SHALL NOT diverge), reject an explicit port outside 1...65535 with `POSIXError(.EINVAL)`,
and validate `timeout` with the QUIC connect-timeout rules (`NaN`/infinite/zero/negative →
`POSIXError(.EINVAL)`; values above 3600 s clamp to 3600). `timeout` defaults to 8 seconds
and is independent of `SMB2Manager.timeout` and of `SMBQUICConfiguration.connectTimeout`.

#### Scenario: Numeric host rejected before network activity
- **WHEN** `server` is a numeric IPv4/IPv6 address in any form the connect policy rejects
- **THEN** the probe throws `POSIXError(.EINVAL)` and no connection attempt is started

#### Scenario: Out-of-range port rejected
- **WHEN** `server` carries an explicit port of `0`, `65536`, or an oversized digit string
- **THEN** the probe throws `POSIXError(.EINVAL)` and no connection attempt is started

#### Scenario: Default and explicit port
- **WHEN** `server` is `fs.example.com` or `fs.example.com:4433`
- **THEN** the handshake targets UDP/443 or UDP/4433 respectively

#### Scenario: Invalid timeout rejected
- **WHEN** `timeout` is `0`, negative, `NaN`, or infinite
- **THEN** the probe throws `POSIXError(.EINVAL)` before any connection attempt

### Requirement: Probe failure outcomes use the existing error vocabulary

The probe SHALL report every non-capture outcome with the same codes the `.quic` connect path
uses, so callers reason about one vocabulary: a TLS handshake failure before any certificate
was delivered (ALPN mismatch, no QUIC listener that still answers TLS, …) → `POSIXError(.EPROTO)`
carrying the Security `OSStatus` as an `NSOSStatusErrorDomain` `NSUnderlyingErrorKey`; an
endpoint that is unreachable or unresponsive within `timeout` → `POSIXError(.ETIMEDOUT)`;
task cancellation → `CancellationError` (even if a chain had already been captured); Linux →
`POSIXError(.ENOTSUP)` (its `EOPNOTSUPP` alias there) before any network activity. Below the
Apple availability floor (iOS 15 / macOS 12 / macCatalyst 15 / tvOS 15 / watchOS 8 /
visionOS 1) the symbol SHALL be unavailable at compile time, like `QUICTransportApple`. If the
deadline expires after a chain was captured but before the handshake outcome was reported,
the probe SHALL return the captured chain rather than `ETIMEDOUT`. The probe SHALL never take
longer than `timeout` (plus teardown) to return.

#### Scenario: TLS failure with no chain
- **WHEN** the handshake is rejected for a TLS reason and no certificate was captured
- **THEN** the probe throws `POSIXError(.EPROTO)` whose `userInfo[NSUnderlyingErrorKey]` is an
  `NSError` in `NSOSStatusErrorDomain`

#### Scenario: Unreachable endpoint (interop-verified)
- **WHEN** the probe targets a TCP-only host on 445, or a UDP port with no QUIC listener
- **THEN** it throws `POSIXError(.ETIMEDOUT)` (or `EPROTO` if the endpoint answers with a
  non-QUIC/TLS failure) no later than `timeout` plus teardown — never a hang

#### Scenario: Cancellation
- **WHEN** the calling task is cancelled while the probe is waiting
- **THEN** the probe throws `CancellationError` and the connection is torn down

#### Scenario: Deadline after capture
- **WHEN** a chain was captured and the deadline then expires before the TLS rejection is
  reported
- **THEN** the probe returns the captured chain

#### Scenario: Linux
- **WHEN** the probe is called on a platform without Network.framework
- **THEN** it throws `POSIXError(.ENOTSUP)` before any network activity

### Requirement: Probe never leaves a connection alive

On every exit path — chain returned, `EPROTO`, `ETIMEDOUT`, `CancellationError`, unexpected
ready — a QUIC connection that was **started** SHALL be cancelled exactly once, and the probe
SHALL NOT return until that teardown has completed, so no started connection outlives the
call. A connection object that was constructed but never started (cancellation observed before
the attempt was committed) performs no network activity and is released without ever having
been a live connection.

#### Scenario: Teardown on every path
- **WHEN** the probe returns or throws for any reason after a connection attempt was started
- **THEN** the underlying connection has been cancelled exactly once before the call returns

#### Scenario: Cancelled before start
- **WHEN** the calling task is cancelled after the connection object was created but before
  the attempt was committed
- **THEN** the probe throws `CancellationError`, the connection was never started, and no
  cancel was issued (there is nothing live to cancel)
