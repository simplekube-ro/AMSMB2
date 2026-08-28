## MODIFIED Requirements

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
and nothing is cancelled) and SHALL cancel the deadline again after `schedule` returns when
the claim was consumed while the timer was arming (so a late-armed timer never survives — see
the deadline requirement below); a loser that wins after the commit but before `start` returns
SHALL neither cancel nor resume inside that window — the starting path finishes the parked
loss after `start` returns, cancelling the started driver exactly once, only then resuming
with the loser's error — so the driver is never cancelled before its start side effect and no
connection activity begins after a losing resume; the in-flight-work flag spanning the whole
attempt clears only after that handoff, so `close()` (which waits on it) never returns while
the committed start or its teardown is still pending; a loser that wins after `start` has
returned performs the single cancel/release and resume itself. It SHALL handle
every `NWConnection` state explicitly — `.setup`/`.preparing` (progress), `.waiting` (classified
by error class at the connection-driver seam: a **transient** wait — no route, DNS, refused,
or any non-TLS condition — is non-terminal: record the error and keep waiting; a **fatal** wait —
a TLS handshake or trust rejection, which no path change can heal — claims the connect outcome as
failure exactly as `.failed` does, without waiting for the deadline), `.ready` (success),
`.failed` (mapped `POSIXError`), `.cancelled` (terminal acknowledgment of a requested cancel) —
and SHALL enforce
a deterministic, always-armed connect deadline from the `connectTimeout` validated and
normalized at construction from `SMBQUICConfiguration.connectTimeout` (design D10 — never from
`SMB2Manager.timeout`; the public initializer applies the shared normalization helper, so a
constructed transport can never hold an invalid deadline). Once `.ready` has won, a later `.failed`/`.cancelled` state event SHALL
route to the established-connection lifecycle (design D8), which discriminates recorded causes
— a `.cancelled` whose local-close cause was recorded by `close()` is the local-close teardown
signal, while an unsolicited event is abnormal transport loss — and SHALL NOT re-enter connect
completion. Error contract: task cancellation → `CancellationError`; `close()` while
connecting → `POSIXError(.ECONNABORTED)`; deadline expiry → `POSIXError(.ETIMEDOUT)`; `.failed`
and fatal `.waiting` → mapped `POSIXError` (design D7; TLS rejection error shape per the
"TLS rejection fails fast with a distinguishable error" requirement).

#### Scenario: Cancellation before start

- **WHEN** the task is already cancelled when `connect(host:port:)` is called
- **THEN** it throws `CancellationError` before any `NWConnection` is created

#### Scenario: Transient waiting is non-terminal

- **WHEN** the injected driver emits a transient `.waiting` (for example `ENETDOWN`,
  `ECONNREFUSED`, or a DNS failure) and later emits `.ready`
- **THEN** `connect` does not fail on the `.waiting` event, the deadline stays armed, and the
  later `.ready` succeeds

#### Scenario: Fatal waiting fails fast

- **WHEN** the injected driver emits a fatal `.waiting` (a TLS handshake/trust rejection) while
  the connect is in progress and the deadline has not fired
- **THEN** the fatal event claims the connect outcome as failure through the same atomic claim as
  `.failed`: `connect` throws the mapped `POSIXError` immediately (the deadline scheduler is
  cancelled, not awaited), the started driver is cancelled exactly once, and the continuation is
  resumed exactly once
- **AND** a fatal `.waiting` that lands after `.ready` has won the claim is routed like any
  post-ready `.failed` (design D8), never re-entering connect completion

#### Scenario: Fatal waiting in the commit-to-start window is a parked loss

- **WHEN** a fatal `.waiting` is delivered after the connect path committed toward starting the
  driver but before `start` has returned
- **THEN** it is handled exactly like a `.failed` in that window per "Loss in the commit-to-start
  window": no cancel and no resume inside the window; the starting path finishes the parked loss
  after `start` returns

#### Scenario: Cancellation while waiting

- **WHEN** the injected driver holds the connection in a transient `.waiting` and the task is
  cancelled
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
- **AND** any `close()` call made while that teardown is pending — whether it is the loss's
  owner or arrived after another loser parked the loss — SHALL NOT return until the started
  driver has been cancelled and the attempt's in-flight work has completed, so a parked
  committed start (or its cancel) can never fire after `close()` has returned

#### Scenario: Concurrent closes during a pending committed-start teardown

- **WHEN** two or more `close()` calls race the commit-to-start window (or each other) while
  the committed start's teardown is pending
- **THEN** every `close()` caller waits for the same single completed teardown, the started
  driver is cancelled exactly once, and the connect continuation is resumed exactly once with
  `POSIXError(.ECONNABORTED)`

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

#### Scenario: A timer armed after an earlier loss is cancelled (no late-armed survivor)

- **WHEN** a loser (close, task cancellation, or a deadline firing synchronously inside
  `schedule`) consumes the connect claim and calls the scheduler's `cancel()` in the
  store-to-schedule window, before `schedule` has recorded a timer, and `schedule` then
  records itself as armed and returns
- **THEN** the connect attempt's post-`schedule` claim re-check notices the consumed claim and
  cancels the late-armed timer before finishing; the final scheduler state is unarmed, the
  continuation resolves exactly once, and no timer remains armed after a terminal connect
  outcome or a completed `close()` — timer self-expiry is never relied upon

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
  deterministic unit coverage (archived `add-quic-transport` tasks 2.3)

## ADDED Requirements

### Requirement: TLS rejection fails fast with a distinguishable error

When the QUIC handshake is rejected for a TLS reason — the server certificate fails the
configured trust policy (`.system` or `.customRoots`), hostname verification fails, or the TLS
handshake otherwise cannot complete — `connect` SHALL fail promptly (bounded by the handshake
itself, never by `connectTimeout`) with `POSIXError(.EPROTO)`. The error SHALL carry the
underlying Security framework status as `userInfo[NSUnderlyingErrorKey]`, an `NSError` in
`NSOSStatusErrorDomain` whose `code` is the `OSStatus` reported by Network.framework, and its
localized description SHALL name it as a QUIC TLS error including that status. Callers SHALL be
able to distinguish a TLS rejection from an unreachable or unresponsive server by error code
alone (`EPROTO` versus `ETIMEDOUT`/other), without inspecting description text. Non-TLS
`.waiting` conditions SHALL NOT be affected: they continue to wait until `.ready`, cancellation,
`close()`, or the deadline.

#### Scenario: Untrusted certificate under system trust fails fast

- **WHEN** the policy is `.system` (or unset) and the server presents a certificate that does not
  chain to a system root (for example a self-signed Windows Server certificate)
- **THEN** `connect` throws `POSIXError(.EPROTO)` well before `connectTimeout` elapses, and
  `(error as NSError).userInfo[NSUnderlyingErrorKey]` is an `NSError` in `NSOSStatusErrorDomain`

#### Scenario: Custom-root rejection fails fast

- **WHEN** the policy is `.customRoots` and the server certificate does not chain to any supplied
  anchor (or does not match the hostname)
- **THEN** `connect` throws `POSIXError(.EPROTO)` promptly with the same underlying-error payload

#### Scenario: TLS error mapping carries the status

- **WHEN** a Network.framework `.tls(status)` error is mapped to `POSIXError`
- **THEN** the result is `EPROTO`, its `NSUnderlyingErrorKey` is an `NSOSStatusErrorDomain`
  `NSError` with `code == status`, and the description contains the numeric status

#### Scenario: Unreachable server is still a timeout

- **WHEN** the QUIC endpoint never answers (no server, filtered UDP port, or transient
  `ECONNREFUSED`/no-route waits)
- **THEN** `connect` still throws `POSIXError(.ETIMEDOUT)` at the deadline — a TLS rejection and
  an unreachable server are no longer the same error code

#### Scenario: Insecure policy is unaffected

- **WHEN** the policy is `.insecureNoVerification` against the same untrusted server
- **THEN** the handshake succeeds (no TLS rejection occurs, so no fatal wait is produced)
