# Design: fix-tcp-one-shot-connect

## D1: Reservation in the existing critical section — no new lock, no seams

`TCPTransportApple` already guards all mutable state with one `NSLock`. The one-shot
reservation is a fourth lock-guarded field:

```swift
private enum ConnectAttempt { case idle, inFlight, connected, failed }
private var _connectAttempt: ConnectAttempt = .idle
```

`connect` performs the closed-guard and the reservation in **one** critical section, before
any bootstrap is constructed:

- `_isClosed` → throw `POSIXError(.ENOTCONN, "transport is closed")` — the conformer's
  existing closed contract, preserved verbatim and checked first (matching the precedence the
  QUIC conformer gives its own closed contract).
- `.idle` → `_connectAttempt = .inFlight` (the reservation; exactly one caller ever takes it).
- `.inFlight` → throw `POSIXError(.EALREADY)`.
- `.connected` → throw `POSIXError(.EISCONN)`.
- `.failed` → throw `POSIXError(.EALREADY)` — retry after a failed attempt is unsupported
  (one instance per connection lifetime; `SMB2Client` builds a fresh transport per connect).

A rejected call therefore performs no work at all: no bootstrap, no channel, no network
activity, and no write to any state the owning attempt uses (`_channel`,
`_connectingChannel`, `_connectCancelled`, the inbound handler).

## D2: Attempt consumption — exactly one terminal transition

- Success: `_channel = channel` and `_connectAttempt = .connected` are set in the same
  critical section, so no observer can see a connected transport still reporting `.inFlight`.
  (Adversarial-review remediation: that critical section is additionally the **publication
  claim** — it first re-checks the terminal events and refuses to publish if close or
  cancellation already won; see D5. The original wording here implied the publication was
  unconditional, which is exactly the defect D5 removes.)
- Failure: the existing multi-`catch` chain is collapsed into a single `catch` that records
  `_connectAttempt = .failed` under the lock first, then applies the unchanged error-mapping
  logic (CancellationError → `ECANCELED`; `POSIXError` pass-through; the post-`get()`
  `Task.isCancelled` re-check; `Self.mapError` fallback). Behavior-preserving: the original
  branches were mutually exclusive and are re-expressed as an `if/else` chain.
- The post-`get()` cancellation re-check (`Task.isCancelled` after a successful future) also
  routes through the `catch`, so it too consumes the attempt.

`close()` during an in-flight attempt aborts it (cancel latch + close whichever channel
exists) **and** — per the D6 lifecycle — waits until the connect tail has fully drained
before returning; the aborted attempt lands in `.failed`, and any later `connect` is
rejected by the closed-guard first — closed wins over attempt state, deterministically.
(The original text here said close "keeps its existing behavior", which allowed the
publication race and the early-returning concurrent close; superseded by D5–D7.)

## D3: `_connectCancelled` reset removed as unreachable

The old first line of `connect` reset `_connectCancelled` so "a fresh connect never inherits
a latched flag from a prior cancelled attempt". Under one-shot there is no second attempt:
in `.idle` with `_isClosed == false`, the flag cannot be set (its only writers are the
in-flight attempt's `onCancel` — which requires the reservation to have been taken — and
`close()`, which latches `_isClosed`). The reset is deleted rather than kept as dead
defensive code.

## D4: Testing without seams

The TCP conformer has no injected driver/scheduler seams and this change does not add any —
the file's established test patterns cover all four contract points deterministically enough:

- **In-flight rejection**: first connect targets TEST-NET-1 (`192.0.2.1`, the file's existing
  pending-connect pattern) with a short bootstrap timeout; the second call must return
  promptly with `EALREADY`. On hosts that fast-fail the reserved address the first attempt is
  already `.failed`, which also maps to `EALREADY` — the assertion is valid in both
  environments, which is precisely why in-flight and after-failure share an error code.
- **Established rejection (`EISCONN`)**: an ephemeral `NWListener` on 127.0.0.1 port 0
  provides a real accepting endpoint; after a successful connect, a second call must fail
  with `EISCONN` while `send` still works against the original channel.
- **After-failure rejection**: first connect to the file's refused-port pattern
  (127.0.0.1:1, 2 s cap) fails; the second call must fail promptly with `EALREADY` (bounded
  well under the network timeout, proving no second bootstrap ran).
- **After-close**: unchanged `ENOTCONN` contract, pinned as a precedence guard test.

Bounded diagnostics: prompt-rejection assertions use elapsed-time bounds far below the
bootstrap timeout, so a regression (a second real connect attempt) fails visibly rather than
hanging the suite.

## D5: Atomic terminal-event-versus-success publication (adversarial-review remediation)

The window between the post-`get()` `Task.isCancelled` re-check and the publication lock let a
racing `close()` or task cancellation close the connecting channel while the success path
still installed it, set `.connected`, and returned success. The remediation folds the re-check
INTO the publication critical section, making publication an atomic claim with a fixed
precedence:

1. `closeState != .open` (close won) → do not install, `_connectAttempt = .failed`, throw
   `POSIXError(.ENOTCONN)` — the conformer's closed contract. Checked FIRST because `close()`
   also sets the cancel latch to abort the initializer; checking the latch first would
   misreport a plain close as `ECANCELED`.
2. `_connectCancelled || Task.isCancelled` (cancellation won) → do not install,
   `_connectAttempt = .failed`, throw `POSIXError(.ECANCELED)`. The direct `Task.isCancelled`
   read preserves the old re-check's coverage of a cancellation landing after
   `withTaskCancellationHandler` exited (no `onCancel` fires then, so no latch is set).
3. Otherwise → `_channel = channel`, `_connectingChannel = nil` (ownership transferred to
   `_channel`), `_connectAttempt = .connected`.

No terminal close/cancellation state can be overwritten by `.connected`, and once `close()`
has claimed `.closing`, no later publication is possible — `_channel` is never repopulated
after `close()` returns.

**Scope (review condition, 2026-07-25)**: the close-then-cancellation precedence and its
`ENOTCONN`/`ECANCELED` mapping apply only to the post-success **publication claim**. A
`close()` that aborts a connect whose future had NOT yet succeeded routes through the
ordinary failure `catch`, which maps the resulting NIO/NW error (typically `ENOTCONN` via
`ChannelError.ioOnClosedChannel`, but other mapped codes such as `EIO`/`ETIMEDOUT`, or
`ECANCELED` when the task was also cancelled, are reachable). The D6 lifecycle still
guarantees `close()` waits for that tail; D5 does not promise which POSIX code the aborted
pre-success connect caller observes.

## D6: Owned close lifecycle `open → closing(waiters) → closed`

`_isClosed` (a boolean set before teardown was awaited) is replaced by a `CloseState`
lifecycle mirroring `QUICTransportApple`:

- The first `close()` caller atomically claims `.open → .closing` and becomes the **owner**
  of the entire teardown: channel closure, `inboundHandler.signalClosed()` (receiver
  unblocking), the connect-tail drain (D7), and `group.shutdownGracefully()` — in that order,
  group shutdown strictly last so no NIO work is outstanding when the loops stop.
- Callers arriving during `.closing` park a continuation in `closeWaiters` (re-checking the
  state under the lock so a caller can never park after the owner published `.closed`) and
  are resumed exactly once, only after the owner publishes `.closed`.
- Only a caller arriving after `.closed` returns immediately — the terminal no-op, distinct
  from a concurrent close, which always waits.
- Teardown failures (`try?` on channel close / group shutdown) remain non-throwing because
  `close()` is non-throwing, but they cannot make any waiter return early: waiters are
  resumed only at the `.closed` publication, which happens after every teardown step ran.
- No lock is held across an `await`, a NIO call, or a continuation resumption.

`connect`'s closed guard and `receive`'s post-close empty-`Data` contract now key off
`closeState != .open`, preserving their observable behavior (a transport in `.closing` is
already closed from the caller's perspective).

## D7: Connect-tail drain and exactly-once channel closure

- `connectWorkInFlight` is set in the same critical section as the one-shot reservation and
  cleared (with `connectWorkWaiters` resumed) by a `defer` that runs after every other exit
  action of `connect` — success, failure, or a lost publication claim. The close owner, after
  closing the channel and unblocking the receiver, parks on `connectWorkWaiters` until the
  flag clears, THEN shuts the group down and publishes `.closed`. A returned `close()`
  therefore proves the connect tail can no longer create or retain resources. (The tail is
  prompt by construction: the owner closed the connecting channel — or the cancel latch makes
  the `channelInitializer` close it on arrival — so the connect future resolves immediately
  rather than waiting out the bootstrap timeout.)
- **Exactly-once channel closure by ownership transfer**: every path that closes a
  never-published channel first takes the reference out of the lock-guarded state
  (`_connectingChannel = nil`) in its own critical section, so exactly one party ever holds
  it: the `channelInitializer` (cancel latch observed on arrival), `onCancel` (task
  cancellation mid-connect), `close()` (owner aborting an in-flight connect), or the losing
  publication claim (the pure post-handler `Task.isCancelled` case, where no `onCancel` ran).
  A failed connect future needs no closer — NIO tears the never-active channel down itself,
  and the `defer` only drops the reference.

## D8: Deterministic race tests through minimal internal seams

The QUIC conformer proves these interleavings with injected driver/scheduler doubles; the TCP
conformer has no driver seam, so the remediation adds the smallest equivalent — two optional
internal gates plus internal observability, all inert in production (`nil` closures, counters
unread):

- `connectPublicationGate` — awaited (when set) immediately before the publication critical
  section, so a test can hold a successful bootstrap at exactly the racy point, let `close()`
  or `task.cancel()` win, then release and assert the losing publication.
- `closeTeardownGate` — awaited (when set) by the close **owner** after channel closure and
  receiver unblocking, before the connect-tail drain and group shutdown, so a test can hold
  the owner mid-teardown and prove concurrent callers stay parked and teardown entry happens
  exactly once.
- Observability: `hasInstalledChannel` (is `_channel` populated), `pendingCloseWaiterCount`
  (`closeWaiters` + `connectWorkWaiters`, the QUIC precedent), and
  `abortedConnectChannelCloseCount` (how many times a never-published channel was closed —
  the exactly-once assertion).

Tests synchronize on these gates/flags via the QUIC suite's bounded `waitUntil` polling of
lock-guarded state — no wall-clock proof, no TEST-NET endpoints, no sleep-based ordering.
