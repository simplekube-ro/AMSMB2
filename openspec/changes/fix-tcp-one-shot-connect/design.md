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
- Failure: the existing multi-`catch` chain is collapsed into a single `catch` that records
  `_connectAttempt = .failed` under the lock first, then applies the unchanged error-mapping
  logic (CancellationError → `ECANCELED`; `POSIXError` pass-through; the post-`get()`
  `Task.isCancelled` re-check; `Self.mapError` fallback). Behavior-preserving: the original
  branches were mutually exclusive and are re-expressed as an `if/else` chain.
- The post-`get()` cancellation re-check (`Task.isCancelled` after a successful future) also
  routes through the `catch`, so it too consumes the attempt.

`close()` during an in-flight attempt keeps its existing behavior (flag + close whichever
channel exists); the aborted attempt then lands in `.failed`, and any later `connect` is
rejected by the closed-guard first — closed wins over attempt state, deterministically.

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
