# quic-transport-apple Specification

## ADDED Requirements

### Requirement: QUICTransportApple implements SMBTransport over Network.framework QUIC

The library SHALL provide a public `QUICTransportApple` class conforming to `SMBTransport`,
backed directly by `NWConnection` with `NWProtocolQUIC` (no NIO, no third-party QUIC stack),
compiled only where `Network` is available and availability-gated to
iOS 15 / macOS 12 / macCatalyst 15 / tvOS 15 / watchOS 8 / visionOS 1 or later (the macCatalyst
floor SHALL be spelled out explicitly in the `@available` annotation — Package.swift declares
`.macCatalyst(.v13)`, so Catalyst is a supported destination whose floor must not be implicit).

#### Scenario: Conformer is a pure byte pipe

- **WHEN** libsmb2 hands the seam an outbound framed SMB2 byte sequence and `send(_:)` is called
- **THEN** the bytes are written to the QUIC stream verbatim, with no SMB-aware inspection,
  reframing, or modification

#### Scenario: Availability gating

- **WHEN** the library is built for a deployment target older than the QUIC availability floor
- **THEN** the package still compiles (package platform minimums are unchanged) and
  `QUICTransportApple` is only usable behind an `@available` check

#### Scenario: macCatalyst floor is explicit and buildable

- **WHEN** the library is built for the macCatalyst destination (package floor macCatalyst 13)
- **THEN** the build succeeds and every QUIC availability annotation names `macCatalyst 15`
  explicitly
- **NOTE** verified by a macCatalyst build check plus annotation inspection in the pre-archive
  sweep (task 5.3)

### Requirement: QUIC handshake uses ALPN "smb", TLS 1.3, and SNI

`connect(host:port:)` SHALL establish a QUIC connection whose TLS 1.3 handshake advertises
exactly the ALPN token `"smb"` and sets the TLS server name (SNI) to the target host name, per
the Microsoft/Samba SMB-over-QUIC interop behavior.

#### Scenario: Handshake parameters (interop-verified)

- **WHEN** `connect(host:port:)` is called
- **THEN** the QUIC security options carry ALPN `"smb"` and SNI equal to `host`
- **AND** the connection targets UDP `port`
- **NOTE** verified by code inspection plus the manual interop gate (completed 2026-07-24, see
  docs/INTEROP-QUIC.md) — the live handshake cannot run in unit tests

#### Scenario: Handshake failure maps to POSIXError

- **WHEN** the QUIC/TLS handshake fails (unreachable host, ALPN rejection, TLS failure)
- **THEN** `connect` throws a `POSIXError` (never a raw Network.framework error), preserving
  `CancellationError` when the task was cancelled

### Requirement: connect claims its outcome atomically — selection and duty assignment in one transition

`connect(host:port:)` SHALL be a self-contained lifecycle that does not depend on libsmb2's
cancellation/timeout machinery (which is not installed during the eager transport connect). It
SHALL guard the connect outcome with a lock-protected state transition through which every
completion path — ready, failure, task cancellation, `close()`, deadline expiry — atomically
claims the outcome **and is assigned its cleanup duty** before any cancellation or cleanup is
performed: exactly one path wins the claim, and a path that loses the claim SHALL perform no
side effects whatsoever. The assigned effects (cancelling the deadline timer, cancelling the
connection, resuming the continuation) SHALL be performed **outside** the lock, by the party the
transition named — which is the winner itself except in the commit-to-start window, where the
duty is transferred to the starting path (see the start handoff below). Consequently the
deadline timer SHALL be cancelled exactly once on every terminal path, but SHALL NOT be assumed
to be cancelled by the winning path in all cases. If `.ready` wins, the transport SHALL retain
the connection for `send`/`receive` (the connection reference SHALL NOT be cleared on
successful connect), and every later losing path SHALL perform no cancellation and no
destructive cleanup (in particular, a losing task-cancellation handler SHALL NOT cancel the
`NWConnection`). If task cancellation, deadline expiry, failure, or `close()` wins before
readiness, the connection SHALL be cancelled and released exactly once (clearing the stored
reference and state handler) and the continuation resumed with the mapped error — with the
start handoff atomic with the claim: a loser that wins before the connect path commits toward
starting the driver SHALL suppress the start entirely (the driver's `start` is never invoked
and nothing is cancelled); a loser that wins after the commit but before `start` returns SHALL
neither cancel nor resume inside that window — the starting path finishes the parked loss after
`start` returns, cancelling the started driver exactly once and only then resuming with the
loser's error, so the driver is never cancelled before its start side effect and no connection
activity begins after a losing resume; a loser that wins after `start` has returned performs
the single cancel/release and resume itself. It SHALL handle
every `NWConnection` state explicitly — `.setup`/`.preparing` (progress), `.waiting`
(non-terminal; record the error and keep waiting), `.ready` (success), `.failed` (mapped
`POSIXError`), `.cancelled` (terminal acknowledgment of a requested cancel) — and SHALL enforce
a deterministic, always-armed connect deadline from the `connectTimeout` validated and
normalized at construction from `SMBQUICConfiguration.connectTimeout` (design D10 — never from
`SMB2Manager.timeout`; the public initializer applies the shared normalization helper, so a
constructed transport can never hold an invalid deadline). Once `.ready` has won, a later `.failed`/`.cancelled` state event SHALL
route to the established-connection lifecycle (design D8), which discriminates recorded causes
— a `.cancelled` whose local-close cause was recorded by `close()` is the local-close teardown
signal, while an unsolicited event is abnormal transport loss — and SHALL NOT re-enter connect
completion. Error contract: task cancellation → `CancellationError`; `close()` while
connecting → `POSIXError(.ECONNABORTED)`; deadline expiry → `POSIXError(.ETIMEDOUT)`; `.failed`
→ mapped `POSIXError` (design D7).

#### Scenario: Cancellation before start

- **WHEN** the task is already cancelled when `connect(host:port:)` is called
- **THEN** it throws `CancellationError` before any `NWConnection` is created

#### Scenario: Cancellation while waiting

- **WHEN** the injected driver holds the connection in `.waiting` and the task is cancelled
- **THEN** the cancellation claims the outcome, exactly one `cancel()` is issued to the
  connection, and `connect` throws `CancellationError`

#### Scenario: Ready-versus-cancel race — winner owns the connection

- **WHEN** `.ready` and a cancellation request race
- **THEN** exactly one outcome wins the atomic claim: `connect` either returns success or
  throws `CancellationError`, and the continuation is resumed exactly once
- **AND** if `.ready` wins, the losing cancellation performs no `cancel()` and no destructive
  cleanup — the established connection remains retained and usable for `send`/`receive`
- **AND** if cancellation wins, exactly one `cancel()` is issued and the connection reference
  is released

#### Scenario: Failure-versus-cancel race

- **WHEN** `.failed` and a cancellation request race
- **THEN** the continuation is resumed exactly once with either the mapped `POSIXError` or
  `CancellationError`, never both, never neither, and the connection is cancelled and released
  exactly once

#### Scenario: Close while connecting

- **WHEN** `close()` is called while `connect` is in flight and wins the claim
- **THEN** `connect` throws `POSIXError(.ECONNABORTED)` and the connection reference is released
- **AND** if the driver had already been started, it is cancelled exactly once; if `close()` won
  before the connect path committed toward starting the driver, the start is suppressed and
  **nothing is cancelled** (there is no connection to cancel). The third phase — a loss landing
  after the commit but before `start` returns — is governed by the "Loss in the commit-to-start
  window" scenario below

#### Scenario: Loss in the commit-to-start window

- **WHEN** `close()`, task cancellation, or deadline expiry wins the claim after the connect
  path has committed toward starting the driver but before the driver's start side effect has
  occurred
- **THEN** nothing is cancelled inside that window; after `start` returns, the started driver
  is cancelled exactly once and `connect` throws the loser's mapped error only after the
  cancel — no connection activity begins after the losing resume

#### Scenario: Deadline expiry

- **WHEN** the connection has not reached `.ready` when the deadline scheduler fires
  `connectTimeout`
- **THEN** `connect` throws `POSIXError(.ETIMEDOUT)` (the description includes the last
  `.waiting` error when one was observed)
- **AND** if the driver had already been started, it is cancelled exactly once; if the deadline
  won before the connect path committed toward starting the driver, the start is suppressed and
  **nothing is cancelled**. The third phase — a loss landing after the commit but before `start`
  returns — is governed by the "Loss in the commit-to-start window" scenario above
- **AND** a deadline that fires after `.ready` has won the claim is a side-effect-free no-op

#### Scenario: Successful connect keeps the connection

- **WHEN** `connect` completes successfully
- **THEN** the connection reference is retained for subsequent `send`/`receive` (it is not
  cleared or cancelled by connect-phase cleanup) and the deadline timer is cancelled

#### Scenario: Post-ready failure routes to the receive path

- **WHEN** the connection fails after `.ready` has already won the connect claim
- **THEN** the failure surfaces through `receive()` as abnormal transport loss
  (`POSIXError`, design D8) and does not touch connect completion

#### Scenario: No double resume or leaked continuation

- **WHEN** any combination of ready, failure, task cancellation, `close()`, and deadline expiry
  occurs, in any order
- **THEN** the connect continuation is resumed exactly once, the party the claim assigned
  performs cleanup exactly once (the winning path itself, or the starting path when the loss was
  parked in the commit-to-start window), and no path that lost the claim performs any side effect
- **NOTE** all race and state scenarios are unit-tested deterministically through the injected
  connection driver and deadline scheduler seams (design D7): the driver scripts `.waiting`/
  `.ready`/`.failed`/`.cancelled` in any interleaving, records `cancel()` requests to prove
  side-effect ownership, and the scheduler advances the deadline without wall-clock waiting.
  TEST-NET endpoints are optional, non-gating integration/smoke coverage only — never required
  deterministic unit coverage (tasks 2.3)

### Requirement: Single bidirectional stream carries the SMB session

The transport SHALL use one QUIC connection with a single bidirectional stream for the entire
SMB session. It SHALL NOT create per-request streams; SMB2 request multiplexing continues inside
the single stream exactly as over TCP.

#### Scenario: All traffic on one stream

- **WHEN** multiple SMB2 requests are in flight concurrently
- **THEN** all outbound and inbound bytes flow over the same bidirectional QUIC stream

### Requirement: receive honors the seam's chunk and EOF conventions

`receive()` SHALL return the next available inbound chunk as `Data`, buffering incrementally
when data arrives faster than it is consumed. After `.ready`, the transport SHALL track a
lock-guarded established-connection lifecycle with recorded causes (design D8):
`ready → localClosing → closed`, or `ready → failed(error)`. The three teardown shapes are:
**peer-originated graceful EOF** (server closes the stream) → `receive()` returns empty
`Data`; **local close** — `close()` SHALL atomically record the local-close cause **before**
calling `NWConnection.cancel()`, so the resulting `.cancelled` state event is never converted
into abnormal loss, and a parked or later `receive()` observes empty `Data`, identically to
`TCPTransportApple`; **abnormal transport loss** — an unsolicited post-ready `.failed`, or a
`.cancelled` with **no** recorded local-close cause → `receive()` throws a `POSIXError`.
Teardown races SHALL have one deterministic winner: the first lock-protected transition out of
`ready` claims the outcome, the parked waiter is resumed exactly once, and a later event SHALL
NOT overwrite an already-recorded local-close result.

#### Scenario: Peer-originated graceful EOF

- **WHEN** the server closes the QUIC stream/connection gracefully
- **THEN** a pending or subsequent `receive()` returns empty `Data`

#### Scenario: Abnormal loss

- **WHEN** the QUIC connection fails (network loss, reset)
- **THEN** a pending or subsequent `receive()` throws a `POSIXError`

#### Scenario: Local close followed by .cancelled is not abnormal loss

- **WHEN** `close()` runs (recording the local-close cause before `NWConnection.cancel()`) and
  the connection then delivers the resulting `.cancelled` state event
- **THEN** the parked or next `receive()` observes empty `Data` (the local-close signal), no
  `POSIXError` is produced, and the `.cancelled` event is a no-op on the recorded result

#### Scenario: .cancelled racing local close has one deterministic winner

- **WHEN** a post-ready `.cancelled` state event races `close()`'s lock-protected cause
  recording
- **THEN** exactly one transition out of `ready` wins under the lock, the parked waiter is
  resumed exactly once, and an already-recorded local-close result is never overwritten by
  the racing event

#### Scenario: Unsolicited post-ready .failed is abnormal loss

- **WHEN** the connection delivers `.failed` after `.ready` with no local `close()` recorded
- **THEN** the parked or next `receive()` throws the mapped `POSIXError`

#### Scenario: Unsolicited .cancelled without a recorded local close is abnormal loss

- **WHEN** the connection delivers `.cancelled` after `.ready` and no local-close cause was
  recorded
- **THEN** the parked or next `receive()` throws a `POSIXError` (abnormal transport loss)

#### Scenario: Exactly-once waiter resumption across teardown races

- **WHEN** any combination of local `close()`, post-ready `.failed`, and post-ready
  `.cancelled` occurs in any order while a `receive()` is parked
- **THEN** the parked continuation is resumed exactly once (empty `Data` if local close won
  the claim; `POSIXError` if abnormal loss won), resources are released exactly once, and
  subsequent `receive()` behavior matches the recorded terminal state
- **NOTE** deterministic through the injected connection driver, which delivers post-ready
  state events on demand (design D7 seams; tasks 2.5)

### Requirement: close is idempotent and releases resources

`close()` SHALL atomically record the local-close cause (design D8) **before** cancelling the
QUIC connection, then cancel the connection, resume any parked `receive()` waiter with empty
`Data` (the local-close EOF signal — an empty-`Data` bridge teardown signal, not a
peer-originated graceful EOF — matching `TCPTransportApple` so the `TransportBridge` sees the
identical teardown signal on both conformers), release all resources, and SHALL be safe to call multiple
times and concurrently with in-flight operations. Because the cause is recorded first, the
`.cancelled` state event produced by `close()`'s own `NWConnection.cancel()` SHALL never be
treated as abnormal transport loss.

The post-`close()` contract is deliberately asymmetric between the two directions, and SHALL use
the same error and EOF signals as `TCPTransportApple` so `TransportBridge` sees the same teardown
signalling on both conformers:

- `receive()` after `close()` SHALL return empty `Data` and SHALL NOT throw. The empty `Data`
  *is* the teardown signal the inbound pump consumes; throwing `ENOTCONN` here would surface a
  local, expected shutdown as an error.
- `send(_:)` SHALL throw `POSIXError(.ENOTCONN)` whenever no usable connection exists — this
  covers both the never-connected transport **and** the transport after `close()`, since
  `close()` releases the driver. There is no teardown-signal convention on the outbound
  direction: a write with nowhere to go is a genuine error.
- `receive()` on a **never-connected** transport (no successful connect ever claimed `.ready`)
  SHALL throw `POSIXError(.ENOTCONN)`, distinguishing "never connected" from "connected, then
  closed".

`POSIXError(.ENOTCONN)` is therefore *not* reserved for the never-connected case alone; it is
the transport's "no usable connection" error, and only `receive()` after a local `close()` is
exempted from it by the empty-`Data` teardown convention.

One ordering difference from `TCPTransportApple` is intentional and recorded rather than
specified as equivalence: when inbound chunks are still buffered at `close()`, `receive()` SHALL
drain those buffered chunks before reporting the close EOF, whereas `TCPTransportApple.receive()`
short-circuits on its closed flag and reports empty `Data` immediately. Both converge on empty
`Data` once the buffer is empty, and neither ever throws for a local close. This is not
observable through `TransportBridge` (its inbound pump is cancelled by `close()`), so the
difference is documented as a known, benign divergence rather than a behavior either conformer
must change.

#### Scenario: Close with a parked receiver

- **WHEN** `close()` is called while a `receive()` continuation is parked
- **THEN** the parked call completes with empty `Data` (the local-close EOF signal) and no
  continuation leaks

#### Scenario: Receive after close

- **WHEN** `receive()` is called after `close()`
- **THEN** it returns empty `Data` without throwing

#### Scenario: Never connected

- **WHEN** `receive()` is called on a transport that was never connected
- **THEN** it throws `POSIXError(.ENOTCONN)`

#### Scenario: Send after close

- **WHEN** `send(_:)` is called on a transport that connected successfully and was then closed
- **THEN** it throws `POSIXError(.ENOTCONN)` (no usable connection), and the bytes reach no
  driver — in contrast to `receive()` after `close()`, which returns empty `Data`

#### Scenario: Send on a never-connected transport

- **WHEN** `send(_:)` is called on a transport that was never connected
- **THEN** it throws `POSIXError(.ENOTCONN)`

#### Scenario: Double close

- **WHEN** `close()` is called twice
- **THEN** the second call is a no-op and no crash or double-release occurs

### Requirement: TLS trust is a mutually exclusive policy, secure by default

The public `SMBQUICConfiguration` type SHALL be platform-neutral (no Security.framework types;
trust anchors are DER-encoded `[Data]`) and SHALL represent trust as a mutually exclusive
`TrustPolicy`: `.system` (default), `.customRoots([Data])`, or `.insecureNoVerification` —
conflicting configuration (custom roots plus insecure) SHALL be unrepresentable. Under
`.system`, the transport SHALL install no custom verify logic at all. Under
`.insecureNoVerification`, chain validation and hostname verification are disabled while
TLS 1.3 encryption and the ALPN `"smb"` requirement remain active.

Under `.customRoots`, the transport SHALL implement this exact fail-closed sequence
(design D5):

1. Convert every DER value with `SecCertificateCreateWithData` **before** creating the
   `NWConnection`; any invalid DER value, and the empty anchor set `.customRoots([])`, SHALL
   fail `connect` with `POSIXError(.EINVAL)` before any network activity.
2. In the verify block, obtain the `SecTrust` from the callback's `sec_trust_t` using
   `sec_trust_copy_ref` (NOT `sec_protocol_metadata_copy_sec_trust`).
3. Create the hostname policy with `SecPolicyCreateSSL(true, host)` and apply it with
   `SecTrustSetPolicies` — hostname verification SHALL remain enforced; custom roots never
   disable it.
4. Install the anchors with `SecTrustSetAnchorCertificates` and require only those anchors
   with `SecTrustSetAnchorCertificatesOnly(true)` — anchors REPLACE system roots; a
   self-signed leaf MAY be supplied as its own anchor.
5. Check every `OSStatus`; any failure SHALL reject verification (fail closed).
6. Evaluate with `SecTrustEvaluateWithError`.
7. Invoke the verify completion exactly once on every path — success, evaluation failure, and
   every `OSStatus` early-out.

#### Scenario: Default system trust with correct host (interop-verified)

- **WHEN** no configuration (or `.system`) is used against a server whose certificate chains to
  a system root and matches the hostname
- **THEN** no verify block is installed, the system default verification path runs, and the
  handshake succeeds
- **NOTE** the no-verify-block-installed half is verified by the `resolveTrust` unit test
  (`.system` resolves to a no-anchors decision carrying no verify material) plus code inspection of
  the production driver's `.system` branch, which installs no verify block. The complementary
  live half — system-trust **enforcement** — was completed 2026-07-24 (see docs/INTEROP-QUIC.md):
  `.system` against the rig (whose cert chains only to the private lab CA) is rejected, proving the
  system path runs untouched. A system-root-chained-cert *success* is not exercised because no
  public-CA SMB-over-QUIC server is available (WS2025 deferred)

#### Scenario: Default trust rejects invalid certificates

- **WHEN** the server presents a certificate that fails system trust or hostname verification
  and the policy is `.system`
- **THEN** the handshake fails and `connect` throws a `POSIXError`

#### Scenario: Custom root with correct hostname

- **WHEN** the policy is `.customRoots` with a private CA (or self-signed leaf) anchor and the
  server presents a matching certificate for the connected hostname
- **THEN** chain evaluation anchors to the supplied certificates and the handshake succeeds

#### Scenario: Custom root with wrong hostname

- **WHEN** the policy is `.customRoots` and the server's certificate chains to a supplied anchor
  but does not match the target hostname
- **THEN** verification fails — custom roots never disable hostname verification

#### Scenario: System roots are excluded under customRoots

- **WHEN** the policy is `.customRoots` and the server's chain validates against a system root
  but not against any supplied anchor
- **THEN** verification fails (anchors replace system roots; they do not augment them)

#### Scenario: Conflicting trust configuration is unrepresentable

- **WHEN** the `SMBQUICConfiguration` API surface is inspected
- **THEN** no combination of values expresses both custom roots and insecure trust
  simultaneously (`TrustPolicy` is a single enum value)

#### Scenario: Insecure mode scope

- **WHEN** the policy is `.insecureNoVerification`
- **THEN** the handshake succeeds regardless of chain or hostname validity, while TLS 1.3
  encryption and ALPN `"smb"` are still required

#### Scenario: Security API / conversion failure fails closed

- **WHEN** a supplied anchor is not valid DER (`SecCertificateCreateWithData` returns nil)
- **THEN** `connect` throws `POSIXError(.EINVAL)` before creating the `NWConnection`
- **WHEN** a Security API call (`SecTrustSetPolicies`, `SecTrustSetAnchorCertificates`,
  `SecTrustSetAnchorCertificatesOnly`) returns a non-success `OSStatus` inside the verify block
- **THEN** the verify completion is invoked exactly once with failure and the handshake fails

#### Scenario: Empty custom-roots anchor set is rejected

- **WHEN** the policy is `.customRoots([])`
- **THEN** `connect` throws `POSIXError(.EINVAL)` before creating the `NWConnection` and before
  any network activity (an empty anchor set can never validate any chain)

#### Scenario: Insecure trust is never the default

- **WHEN** an `SMBQUICConfiguration` is created without arguments
- **THEN** `trustPolicy` is `.system` and system verification applies
