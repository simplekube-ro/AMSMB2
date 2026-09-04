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
the connection for `send` and inbound delivery (the connection reference SHALL NOT be cleared on
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
  cleanup — the established connection remains retained and usable for `send` and inbound delivery
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
- **THEN** the connection reference is retained for subsequent `send` and inbound delivery (it is not
  cleared or cancelled by connect-phase cleanup) and the deadline timer is cancelled

#### Scenario: Post-ready failure routes to the receive path

- **WHEN** the connection fails after `.ready` has already won the connect claim
- **THEN** the failure is delivered to the `onReceive` handler as abnormal transport loss (a
  `POSIXError` failure, design D8) and does not touch connect completion

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

### Requirement: receive honors the seam's chunk and EOF conventions

Inbound bytes SHALL be pushed to the `onReceive` handler supplied to `connect` as each chunk
arrives on the connection's private queue, in arrival order, with no intermediate buffer and no
parked waiter in the transport. The handler SHALL be installed only after the one-shot connect
reservation has succeeded (a rejected repeat `connect` never replaces the live handler), and a
`connect` that throws SHALL never invoke it: nothing the connection produces before `.ready` has
won the connect claim is delivered (the first receive is armed before readiness), and nothing is
delivered once a loss outcome has claimed the connect. After `.ready`, the transport SHALL track a lock-guarded
established-connection lifecycle with recorded causes (design D8): `ready → closed`, or
`ready → failed(error)`. The three teardown shapes are: **peer-originated graceful EOF** (server
closes the stream) → the handler is invoked once with empty `Data`; **local close** — `close()`
SHALL atomically record the local-close cause **before** calling `NWConnection.cancel()`, so the
resulting `.cancelled` state event is never converted into abnormal loss, and the handler is not
invoked at all for it, identically to `TCPTransportApple`; **abnormal transport loss** — an
unsolicited post-ready `.failed`, or a `.cancelled` with **no** recorded local-close cause → the
handler is invoked once with a `POSIXError` failure. EOF and failure are terminal: nothing is
delivered after either — in particular, a peer EOF followed by the connection's later
`.cancelled` or `.failed` state event delivers nothing further. Teardown races SHALL have one
deterministic winner: the first
lock-protected transition out of `ready` claims the outcome, the handler receives at most one
terminal delivery, and a later event SHALL NOT overwrite an already-recorded local-close result.

#### Scenario: Peer-originated graceful EOF

- **WHEN** the server closes the QUIC stream/connection gracefully
- **THEN** the handler is invoked exactly once with empty `Data` and never again

#### Scenario: Abnormal loss

- **WHEN** the QUIC connection fails (network loss, reset)
- **THEN** the handler is invoked exactly once with a `POSIXError` failure and never again

#### Scenario: Nothing is delivered before ready wins

- **WHEN** the connection produces a chunk, a receive error or an EOF before `.ready` has won
  the connect claim
- **THEN** the handler is not invoked, the connect outcome is decided by the state handler
  alone, and a chunk arriving after `.ready` has won is delivered normally

#### Scenario: Connect that loses never delivers afterwards

- **WHEN** `.failed`, deadline expiry, task cancellation or `close()` claims the connect outcome
  and the connection afterwards produces a chunk, a failure or an EOF
- **THEN** the handler is never invoked

#### Scenario: Rejected repeat connect keeps the first receiver

- **WHEN** `connect` is called again on an instance whose attempt is in flight or established,
  with a different handler
- **THEN** the call is rejected as the one-shot contract requires and inbound bytes continue to
  reach the first call's handler

#### Scenario: EOF followed by a later state event delivers nothing

- **WHEN** the peer closes the stream (empty inbound delivery) and the connection afterwards
  delivers `.cancelled` or `.failed`
- **THEN** the handler received exactly one delivery (the empty `Data`) and nothing for the later
  event

#### Scenario: Chunks are delivered in arrival order

- **WHEN** the connection delivers several inbound chunks in succession
- **THEN** the handler receives each chunk as its own delivery, in the order the connection
  produced them, with no coalescing and no loss

#### Scenario: Local close followed by .cancelled is not abnormal loss

- **WHEN** `close()` runs (recording the local-close cause before `NWConnection.cancel()`) and
  the connection then delivers the resulting `.cancelled` state event
- **THEN** the handler is not invoked for the `.cancelled` event, no `POSIXError` is produced,
  and the event is a no-op on the recorded result

#### Scenario: .cancelled racing local close has one deterministic winner

- **WHEN** a post-ready `.cancelled` state event races `close()`'s lock-protected cause
  recording
- **THEN** exactly one transition out of `ready` wins under the lock, the handler receives at
  most one delivery (a failure only if abnormal loss won), and an already-recorded local-close
  result is never overwritten by the racing event

#### Scenario: Unsolicited post-ready .failed is abnormal loss

- **WHEN** the connection delivers `.failed` after `.ready` with no local `close()` recorded
- **THEN** the handler is invoked once with the mapped `POSIXError` failure

#### Scenario: Unsolicited .cancelled without a recorded local close is abnormal loss

- **WHEN** the connection delivers `.cancelled` after `.ready` and no local-close cause was
  recorded
- **THEN** the handler is invoked once with a `POSIXError` failure (abnormal transport loss)

#### Scenario: Exactly-once waiter resumption across teardown races

- **WHEN** any combination of local `close()`, post-ready `.failed`, and post-ready
  `.cancelled` occurs in any order after `.ready`
- **THEN** the handler receives at most one terminal delivery (none if local close won the
  claim; one `POSIXError` failure if abnormal loss won), resources are released exactly once,
  and no delivery follows the recorded terminal state
- **NOTE** deterministic through the injected connection driver, which delivers post-ready
  state events on demand (design D7 seams; tasks 2.5 of the QUIC change)

### Requirement: close runs a first-caller-owned lifecycle and every caller observes completed teardown

`close()` SHALL run an explicit close lifecycle (`open → closing → closed`, design D7/D8): the
first caller atomically becomes the teardown owner, records the local-close cause **before**
cancelling the QUIC connection, then — on a dedicated non-cooperative teardown queue — cancels
the connection, terminates inbound delivery (the `onReceive` handler is not invoked for anything
the close itself produces — matching `TCPTransportApple` so the `TransportBridge` sees the
identical silent teardown on both conformers), resolves the connect continuation when close won
the connect claim, waits for any
in-flight connect work (a committed `start()` that has not returned — including the
ready-mid-start case — its post-start handoff, or the deadline-arming tail with its late-armed
re-check), and only then transitions to fully closed and resumes every waiting caller. Because
the cause is recorded first, the `.cancelled` state event produced by `close()`'s own
`NWConnection.cancel()` SHALL never be treated as abnormal transport loss.

`close()` SHALL be safe to call multiple times and concurrently with in-flight operations,
with these mandatory invariants: only the owner performs cancellation/resource release; every
caller arriving while teardown is running waits for that same completed teardown (a concurrent
second close is NOT a mere no-op — it must not return before teardown finishes); only a call
made after a prior close fully completed may return immediately as the terminal no-op; exactly
one cancel and exactly one resumption per owned resource; and no lock is held across an await,
a driver or deadline call, or a continuation resumption. Once any `close()` has returned, no
start, inbound delivery, parked teardown, close-owned resource release, or armed timer remains
outstanding (the sole remnant is resolution-only: a `connect()` caught between its reservation
and its continuation store aborts itself with `ECONNABORTED` afterwards, creating no driver or
timer activity).

The post-`close()` contract is deliberately asymmetric between the two directions, and SHALL use
the same error and EOF signals as `TCPTransportApple` so `TransportBridge` sees the same teardown
signalling on both conformers:

- Inbound delivery after `close()` has begun SHALL NOT occur: the handler is not invoked for
  the connection's own teardown events, and the handler closure is released when the close
  completes. A local, expected shutdown never surfaces on the inbound side at all.
- `send(_:)` SHALL throw `POSIXError(.ENOTCONN)` whenever no usable connection exists — this
  covers both the never-connected transport **and** the transport after `close()`, since
  `close()` releases the driver. There is no teardown-signal convention on the outbound
  direction: a write with nowhere to go is a genuine error.

`POSIXError(.ENOTCONN)` is the transport's "no usable connection" error on the outbound
direction; the inbound direction has no post-close signal at all. Because the transport holds
no inbound buffer, there is nothing to drain at `close()` and no ordering difference from
`TCPTransportApple` on the inbound side.

#### Scenario: Close with a parked receiver

- **WHEN** `close()` is called on an established connection whose handler is idle, waiting for
  the next inbound chunk
- **THEN** the handler is not invoked for the resulting `.cancelled` event, and the handler
  closure is released once `close()` completes (no continuation exists to leak)

#### Scenario: Receive after close

- **WHEN** the connection produces any further inbound or state event after `close()` has begun
- **THEN** the handler is not invoked — the inbound side is silent after close and never throws

#### Scenario: Never connected

- **WHEN** a transport that was never connected is closed or released
- **THEN** it holds no handler, nothing is ever delivered, and no resource is released twice

#### Scenario: Send after close

- **WHEN** `send(_:)` is called on a transport that connected successfully and was then closed
- **THEN** it throws `POSIXError(.ENOTCONN)` (no usable connection), and the bytes reach no
  driver — the inbound side, by contrast, is simply silent after close

#### Scenario: Send on a never-connected transport

- **WHEN** `send(_:)` is called on a transport that was never connected
- **THEN** it throws `POSIXError(.ENOTCONN)`

#### Scenario: Concurrent close during established teardown waits for completion

- **WHEN** two `close()` calls race while the first is tearing down an established connection
  (driver cancellation still in progress)
- **THEN** neither call returns before the driver cancellation has completed, the driver is
  cancelled exactly once, and both callers then return

#### Scenario: Concurrent close during a pre-commit connect abort waits for the attempt tail

- **WHEN** two `close()` calls race while the first is aborting a connect attempt that has not
  committed toward `driver.start()` (e.g. the deadline is still arming)
- **THEN** the connect resolves exactly once with `POSIXError(.ECONNABORTED)`, the driver
  never starts, both close callers wait for the attempt's in-flight work to finish (including
  cancelling a late-armed timer), and only then return

#### Scenario: Close during ready-mid-start waits for the start tail

- **WHEN** `.ready` won the connect claim while `driver.start()` had not yet returned, and
  `close()` is called
- **THEN** `close()` cancels the ready driver (exactly once) but does not return until
  `start()` has returned and the attempt's handoff completed; after `close()` returns, no
  start tail or teardown operation remains outstanding

#### Scenario: Close after a fully completed close is a prompt no-op

- **WHEN** `close()` is called after a prior `close()` has fully completed its teardown
- **THEN** the call returns promptly, performs no second teardown, and no crash or
  double-release occurs
