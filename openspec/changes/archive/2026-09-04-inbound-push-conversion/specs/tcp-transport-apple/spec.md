## MODIFIED Requirements

### Requirement: Connect, send, receive, close over a NIO channel

`connect(host:port:onReceive:)` SHALL establish a TCP connection via a Network.framework-backed
NIO channel and support cancellation. `send(_:)` SHALL write bytes to the channel. Inbound bytes
SHALL be pushed to the `onReceive` handler as each chunk arrives on the channel's event loop, in
arrival order, with no intermediate buffer in the transport: graceful end-of-stream is delivered
once as empty `Data`, a channel error once as a `POSIXError` failure, and nothing is delivered
after either or once `close()` has begun. A zero-length channel read SHALL NOT be delivered (and
SHALL NOT be counted as a transport read), so empty `Data` reaches the handler only as EOF. The
handler SHALL be installed only after the one-shot connect reservation below has succeeded, and
a `connect` that throws SHALL never invoke it. `close()` SHALL tear the channel down cleanly.

#### Scenario: Inbound bytes are buffered for incremental drain

- **WHEN** the channel receives more bytes than a single bridge `recv` consumes
- **THEN** every chunk is delivered to the handler as it arrives, in order and without loss, and
  the surplus the bridge has not yet drained is held in the bridge's own store — the transport
  neither coalesces nor retains any of it

#### Scenario: Graceful close yields EOF

- **WHEN** the channel reaches end-of-stream
- **THEN** the handler is invoked exactly once with empty `Data` (graceful EOF) and never again

#### Scenario: Connect that loses the publication race never delivers

- **WHEN** the bootstrap succeeds but task cancellation or `close()` wins the publication claim,
  so `connect` throws and the never-published channel is closed
- **THEN** the handler is not invoked for that channel's teardown

#### Scenario: Zero-length read is not EOF

- **WHEN** the channel delivers a read with no readable bytes while the connection is open
- **THEN** the handler is not invoked, no transport-read signpost is emitted, and a later
  non-empty read is delivered normally

#### Scenario: Delivery stops when close begins

- **WHEN** `close()` is called while the channel is live
- **THEN** the handler receives no delivery for the channel teardown that the close itself
  produces, and the handler closure is released once `close()` completes

`connect(host:port:onReceive:)` SHALL additionally be strictly **one-shot** per instance: the first
call atomically reserves the instance's single connect attempt under the state lock, before
any bootstrap or channel exists, and every other call SHALL fail promptly and
deterministically without creating a bootstrap, a channel, or any network activity, and
without touching the owning attempt's channel or state. The rejection error mapping SHALL
be: attempt in flight → `POSIXError(.EALREADY)`; after successful connect →
`POSIXError(.EISCONN)`; after a failed attempt → `POSIXError(.EALREADY)` (retry after a
failed first attempt is NOT supported — one instance maps to one connection lifetime;
callers construct a fresh transport, as `SMB2Client` does); after `close()` →
`POSIXError(.ENOTCONN)` (the conformer's existing closed-transport contract, checked before
the attempt state).

#### Scenario: Second connect while an attempt is in flight is rejected

- **WHEN** `connect` is called while another `connect` call's attempt is still in flight
- **THEN** the second call fails promptly with `POSIXError(.EALREADY)`, starts no bootstrap,
  and the owning attempt proceeds to its own outcome unaffected

#### Scenario: Connect after an established connection is rejected

- **WHEN** `connect` is called after a previous call connected successfully
- **THEN** it fails promptly with `POSIXError(.EISCONN)` and the established channel remains
  installed and usable for `send` and inbound delivery — and the first call's handler, not the
  rejected call's, keeps receiving

#### Scenario: Retry after a failed attempt is rejected

- **WHEN** the first connect attempt has failed and `connect` is called again
- **THEN** the call fails promptly with `POSIXError(.EALREADY)` — bounded well under the
  connect timeout, proving no second network attempt ran

#### Scenario: Connect after close keeps the existing closed contract

- **WHEN** `connect` is called after `close()`
- **THEN** it throws `POSIXError(.ENOTCONN)` (the pre-existing closed-transport error),
  regardless of whether an attempt had run before the close

Success publication SHALL additionally be an **atomic claim** under the state lock: the
critical section that installs the channel and records `.connected` SHALL first re-check the
terminal events with precedence close-then-cancellation. If `close()` won before publication,
`connect` SHALL NOT install the channel, SHALL NOT return success, and SHALL throw
`POSIXError(.ENOTCONN)`; if task cancellation won before publication, `connect` SHALL NOT
install the channel and SHALL throw `POSIXError(.ECANCELED)`. No terminal close/cancellation
state may be overwritten by `.connected`, the losing path SHALL close/release the connecting
channel exactly once (ownership transfer under the lock), and once `close()` has returned the
channel slot SHALL never be repopulated.

#### Scenario: Close wins the race immediately before channel publication

- **WHEN** a successful bootstrap is gated immediately before the publication critical
  section and `close()` wins the race
- **THEN** `connect` does not return success (it throws `POSIXError(.ENOTCONN)`), the channel
  is not installed, the never-published channel is closed exactly once, and `close()` returns
  only after the gated connect tail has fully drained

#### Scenario: Task cancellation wins the race immediately before channel publication

- **WHEN** a successful bootstrap is gated immediately before the publication critical
  section and the enclosing task's cancellation wins the race
- **THEN** `connect` throws `POSIXError(.ECANCELED)`, no channel remains installed, and the
  never-published channel's teardown occurs exactly once

`close()` SHALL run a first-caller-**owned** lifecycle `open → closing(waiters) → closed`:
exactly one caller owns channel closure, delivery termination, connect-tail draining, and
event-loop-group shutdown (group shutdown last); callers arriving during `.closing` SHALL
park and return only after that owner's fully-completed teardown; only a caller arriving
after `.closed` SHALL return immediately as the terminal no-op. Teardown failures MAY be
swallowed (close is non-throwing) but SHALL NOT let any waiter return before the teardown
completed. A `close()` during an in-flight or publication-gated connect SHALL prevent any
later channel publication and SHALL wait until the connect tail can no longer create or
retain resources. No lock may be held across an `await`, a NIO call, or a continuation
resumption, and every waiter SHALL be resumed exactly once. These interleavings SHALL be
proven by deterministic tests gated on internal seams — not by sleeps, TEST-NET endpoints,
or wall-clock assumptions.

#### Scenario: Concurrent close callers wait for the owner's completed teardown

- **WHEN** two `close()` calls race while the owner's teardown is gated mid-way
- **THEN** both callers remain suspended while the gate holds, exactly one caller entered the
  teardown, and releasing the gate completes that single teardown and resumes both callers

#### Scenario: Close after a fully-completed close is a terminal no-op

- **WHEN** `close()` is called after a prior `close()` has fully completed its teardown
- **THEN** it returns promptly without entering the teardown a second time

#### Scenario: Close racing a publication-gated connect satisfies the owned lifecycle

- **WHEN** `close()` races a connect that is gated immediately before publication
- **THEN** the close owner remains suspended until the connect tail has drained, the connect
  does not publish, and both the close lifecycle and the atomic-publication contract hold on
  the same run
