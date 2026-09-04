## Context

See proposal.md — Why. The parts of the current inbound path that matter for the design:

- `TransportBridge.connect(host:port:)` runs the eager transport connect on the caller's task
  before the seam is installed on `eventLoopQueue`; the bridge is created before that and owns
  the transport for its whole life. `startPumps()` (both pump tasks) runs only after
  `smb2_set_transport` / `smb2_connect_share_async` succeed. Any bytes, EOF or error that arrive
  between the eager connect and `startPumps()` are today held inside the transport
  (`InboundBufferingHandler.buffer`, `QUICTransportApple.inboundChunks`).
- Both conformers already receive inbound data as callbacks on a single serial queue:
  `InboundBufferingHandler.channelRead/channelInactive/errorCaught` on the NIOTS event loop, and
  `QUICConnectionDriver.start(onState:onReceive:)` on the connection's private queue. Their
  `receive()` implementations exist only to hand those callbacks to the pump `Task`.
- The bridge's inbound-ready handler is already designed to run "on an unspecified thread": it
  takes `serviceFlagLock`, flips the debounce flag, and does `eventLoopQueue.async`. Nothing in
  it blocks or suspends.
- `cRecv` runs on `eventLoopQueue` under the bridge lock; `appendInbound` takes the same lock
  from whichever thread delivers. Moving delivery from the cooperative pool to the network queue
  changes which thread contends, not the locking discipline.
- `bridge.close()` sets `isClosed` under the lock, nils `_onInboundReady`, cancels the pump
  tasks and calls `transport.close()` from a detached `Task`. `cRecv` returns `ECONNRESET` once
  `isClosed` is set, regardless of buffered bytes.
- Signposts: `TransportRead` is emitted in `channelRead`, `InboundChunk` in `appendInbound`.
  `scripts/profile-summary.sh` pairs them by FIFO byte-sum to derive the "pump-hop latency" and
  the coalescing ratio; `docs/PROFILING.md` reads those as the pull loop's backlog signal.
- Test doubles conforming to `SMBTransport`: `MockTransport` (actor, send-loopback into
  `receive()`), `GatedOutcomeTransport` and `GatedConnectTransport` (actors whose `receive()`
  never returns). `TransportBridgeTests` work around the loopback by starting only one pump per
  test; `SMB2ServicingLoopTests` uses `sendsAreDropped: true` to stop libsmb2's NEGOTIATE from
  being fed back to itself.

## Goals / Non-Goals

**Goals:**

- One executor hop per chunk: network queue → `eventLoopQueue`. No `Task` on the inbound path.
- The transport protocol makes it impossible to connect without a receiver, so no conformer needs
  a "bytes arrived but nobody is listening" buffer.
- Byte-for-byte identical behaviour at `cRecv`: same gather, same short reads, same return
  precedence, same debounce.
- Exactly the same teardown signals on both conformers as today, seen from the bridge.
- The baseline metrics stay computable from the same signposts and the same script, and the
  procedure document says how to read them after the change.

**Non-Goals:**

- Backpressure from libsmb2 to the network (neither path has it; unchanged).
- Any change to `maximumReceiveLength` (#46), to signpost names/formats, or to
  `scripts/profile-summary.sh` and its fixture.
- Keeping `receive()` as a deprecated shim. It cannot be implemented on top of a push transport
  without re-adding the buffer and waiter this change removes, and 6.0 is the break window.
- The Linux path (libsmb2's own socket; no seam).

## Decisions

### D1 — The receiver is a parameter of `connect`, not a separate setter

```swift
public protocol SMBTransport: Sendable {
    func connect(
        host: String, port: Int,
        onReceive: @escaping @Sendable (Result<Data, POSIXError>) -> Void
    ) async throws
    func send(_ bytes: Data) async throws
    func close() async
}
```

`onReceive` is invoked once per inbound chunk with `.success(bytes)`, once with
`.success(Data())` for graceful EOF, or once with `.failure(error)` for abnormal loss. EOF and
failure are terminal: nothing is delivered after either, and nothing is delivered once `close()`
has begun. Invocations are serial and in arrival order. The handler must return promptly and
must not suspend (it runs on the transport's network queue).

*Why a connect parameter.* The alternative the issue sketches — `setReceiveHandler(_:)` plus an
unchanged `connect(host:port:)` — needs a rule ("register before connect") that lives only in
documentation, and every conformer then has to define what happens when bytes arrive with no
handler: buffer them (re-adding the state this change deletes), drop them (a silent hang for a
misuse), or precondition (a crash on a path that also fires for benign EOF during close). Putting
the handler in `connect`'s signature makes the rule unrepresentable to violate, needs no
"unregistered" state in any conformer, and reads naturally: a connection has a receiver from the
moment it exists. The cost is that every test call of `connect(host:port:)` on the two
conformers (13 in `TCPTransportAppleTests`, 23 in `QUICTransportAppleTests`) gains an argument —
mechanical, and mostly through the QUIC tests' `makeTransport` helper.

*Alternatives considered.* An `AsyncStream<Data>`-returning `inbound` property: keeps a
cooperative-pool consumer, which is the hop being removed. An async `setReceiveHandler` so actor
conformers can satisfy it: same ordering problem as the sync setter, plus an extra suspension in
the connect path.

*Payload type.* `Result<Data, POSIXError>`, carried by the public `InboundReceiver` typealias
declared next to the protocol (unguarded, so Linux conformers share it). It is `Sendable` outright, which matters because
`SMBTransport.swift` and `MockTransport.swift` compile on Linux, where Swift 6.1 hard-errors on a
non-`Sendable` `any Error` leaving the actor-isolated mock through a `@Sendable` closure (macOS
only warns). It also matches what `QUICConnectionDriver.start(onReceive:)` already delivers and
the library's `POSIXError`-only error convention; both conformers already map every NIO/NW error
to `POSIXError` before surfacing it. `make linuxtest` is the gate for this decision (task 4.3).

*Failed and rejected connects.* A `connect` that throws never invokes its handler. Both
conformers reserve their single one-shot attempt in the first lock-protected section of
`connect`; the handler is installed only after that reservation succeeds, so a rejected repeat
call (`EALREADY` / `EISCONN` / the closed-transport error) never replaces the live receiver.

### D2 — The bridge is the receiver; it captures itself weakly

`TransportBridge.connect(host:port:)` calls
`transport.connect(host: host, port: port) { [weak self] result in self?.deliverInbound(result) }`.
`deliverInbound(_ result: Result<Data, POSIXError>)` is the transport's entry point: under the
lock, if `isClosed` it returns (the delivery is dropped — `cRecv` would answer `ECONNRESET`
anyway and no signal must fire after `_onInboundReady` was cleared); otherwise it appends
non-empty bytes (emitting `InboundChunk`), or sets `inboundEOF` for empty `Data`, or sets
`inboundError`, then fires `_onInboundReady` outside the lock exactly as `appendInbound` /
`setInboundEOF` / `setInboundError` do today. Those three private helpers collapse into one
private `applyInbound` that `deliverInbound` and the outbound pump share: `outboundPump()`'s
`transport.send` failure, which calls `setInboundError` today, becomes the same error path (the
send error is `any Error` there; it is stored as today, not re-typed).

*No bridge-side terminal-once.* The bridge keeps exactly one guard, `isClosed`. It does not
track "EOF or error already seen": `cRecv`'s precedence (closed → bytes → EOF → error →
would-block) stays byte-for-byte what it is today, and terminal-once is the conformer's
obligation (D3, D4), which is what the transport specs require.

*Why weak.* bridge → transport → handler → bridge would otherwise be a cycle held until the
transport releases the closure. Weak capture makes the bridge's lifetime what it is today
(libsmb2's `userdata` retain, balanced in the close trampoline) with no dependence on conformer
hygiene. Conformers still release the closure in `close()` (D4) so no transport keeps a dead
bridge's closure around.

*Why the inbound-ready handler stays a separate registration, and the window it creates.*
`setInboundReadyHandler` is set by `SMB2Client` during seam installation on `eventLoopQueue`,
after the eager connect has returned on the caller's task, and it is what the debounce is
attached to. Today the inbound pump is started after that registration in the same install
block, so every append has always signalled. With push, a delivery can land between the eager
connect and the registration — and a chunk sitting in the FIFO with no signal is a lost wakeup,
because `serviceContextForSeam` (called only from the inbound-ready callback) is the one path
that services with `POLLIN`: `flushOutboundForSeam` services `POLLOUT` only and the seam timer
calls `smb2_service_timeout` then the flush; neither reads. Such a chunk would be drained only
by a later delivery's signal; if it is the last one, the connect hangs to its timeout.

So `setInboundReadyHandler` closes the window itself: under the lock it stores the handler and
reads whether the store already holds bytes, EOF or an error; if so it invokes the handler once,
outside the lock. From then on every delivery signals as today. The window is rare rather than
routine because of an ordering invariant in `connectWithBridge` that is now load-bearing: the
outbound pump is started *after* the inbound-ready handler is registered, so no outbound byte
(NEGOTIATE) can leave before registration and a server cannot have anything to answer; the only
pre-registration deliveries are unsolicited ones (an immediate server close or a transport
error), which are exactly the ones that must not hang the connect. `SMB2Client` is not changed
beyond `startPumps()` → `startOutboundPump()`; the invariant is recorded in a comment at the
call site and pinned by the bridge test in task 2.1 that registers after a delivery and asserts
the signal fires.

### D3 — Conformers forward; they do not buffer

- `TCPTransportApple`: `InboundBufferingHandler` becomes `InboundForwardingHandler`. Its state is
  the handler closure and a `terminated` flag under its lock. `connect` terminates delivery
  (`signalClosed()`) on every throwing exit *before* the orphaned channel is closed — on the
  cancellation-won and close-won publication outcomes the bootstrap has already succeeded and
  the channel is active, so its close would otherwise fire `channelInactive` into the handler of
  a `connect` that throws. `channelRead` returns early on a
  zero-length read — before the `TransportRead` signpost and before forwarding — because
  `deliverInbound` reads empty `Data` as EOF (today `appendInbound` skips empty chunks and EOF
  is a separate entry point; QUIC's `armReceive` already guards with `!content.isEmpty`).
  Otherwise it copies the `ByteBuffer` to `Data` (unchanged — the copy at the NIO boundary is
  design D4 of the transport change), emits `TransportRead`, and forwards `.success(data)`.
  `channelInactive` forwards `.success(Data())` once. `errorCaught` forwards
  `.failure(Self.mapError(error))` once and closes the channel. After the first terminal
  delivery, or once `signalClosed()` has run, the flag short-circuits every later callback.
  `inboundHandler` is a stored `let` created at init and added to the pipeline by the channel
  initializer; `connect` installs the closure into it right after the one-shot reservation
  succeeds and before the bootstrap runs, so no `channelRead` can precede the closure and no
  rejected connect can touch it.
- `QUICTransportApple`: the closure is stored under the lock in `connect`, after the one-shot
  reservation succeeds. `handleReceive` forwards in place of parking/buffering. `.success(empty)`
  → EOF (terminal). `.success(bytes)` → deliver. `.failure` → `lifecycle = .failed`, deliver the
  failure (terminal). The post-ready `.cancelled` path that today resolves `abnormalLoss(waiter)`
  delivers `.failure(POSIXError(.ECONNRESET))` instead, still only when no local-close cause was
  recorded (D8 of the QUIC change is unchanged: the first lock-protected transition out of `ready`
  wins and a recorded local close is never overwritten). Terminal-once is one lock-guarded
  `deliveryTerminated` flag, checked and set by all four producers — the EOF branch, the
  chunk-path failure, post-ready `.failed`, post-ready `.cancelled` — and by the `open → closing`
  transition, and by `resolveConnect`'s loss outcomes (failure, deadline, cancellation, close
  winning the claim), so a `connect` that throws can never deliver afterwards. It is needed
  because the EOF branch does not move `lifecycle` today, so a peer EOF followed by the
  connection's routine `.cancelled` would otherwise deliver a failure after a terminal delivery.
  Deliveries are additionally gated on `.ready` having won the connect claim (`everReady`,
  checked in the same lock-protected receiver take): the driver arms its first receive before
  `.ready`, so a chunk, EOF or receive error produced during setup is dropped whole — including
  the state mutation the receive-failure branch used to make, which could fail the lifecycle and
  release the driver of a connection that then reached `.ready`. A genuine setup failure still
  reaches the caller through the state handler's `.failed` → `resolveConnect`. `inboundChunks`, `receiveWaiter`, `receiveError` and `inboundEOF` are
  deleted; the "drain buffered chunks before close EOF" divergence from TCP disappears with
  them, and so does the never-connected `receive()` → `ENOTCONN` case (there is no call to
  make).
- Each conformer stores the closure under its existing lock and reads it under that lock at
  delivery time, calling it outside the lock (the handler takes the bridge lock; never nest).

### D4 — Delivery stops when `close()` begins; the closure is released when it ends

`close()`'s first lock-protected transition (`open → closing` on both conformers) also marks
delivery terminated (`signalClosed()` on TCP, `deliveryTerminated` on QUIC), so a
`channelInactive` / `.cancelled` produced by the close itself is never forwarded. The closure reference is nilled when the teardown owner publishes `.closed`. The
bridge does not depend on either (D2 handles late deliveries and lifetime); this is the contract
external conformers are held to, and it is what keeps `TCPTransportApple.signalClosed()` and
QUIC's local-close ack the same "silent teardown" the bridge sees today (the pull loop was
cancelled by `bridge.close()` before it could observe the transport's close EOF).

### D5 — Bridge lifecycle API

`startInboundPump()` and `inboundPumpTask` are deleted. `startPumps()` is deleted too, and
`SMB2Client`'s seam install calls `bridge.startOutboundPump()` — one call, one pump, no
ambiguity about what "pumps" means. `close()` cancels the outbound task only. The class doc
comment and the `_onInboundReady` comment ("all subsequent calls come from the async inbound-pump
Task") are corrected.

### D6 — Test doubles

- `MockTransport` stays an actor. `connect(host:port:onReceive:)` stores the closure (after
  honouring `connectBehavior`). Test-side injection: `deliver(_ bytes: Data)`,
  `signalGracefulEOF()`, `signalError(_:)` invoke the stored closure (terminal-once, nothing
  after `close()`). `send(_:)` appends to a `sent` log readable by tests (`sentChunks()` and a
  `waitForSent(count:)` that parks a continuation until the log reaches the count), so
  outbound-path tests observe delivery without any loopback. The loopback and
  `sendsAreDropped` are deleted; `SMB2ServicingLoopTests.testConnectWithBridgeCompletesWithoutHang`
  no longer needs the flag because nothing is fed back into libsmb2.
- A small `InboundRecorder` (final class, lock, `[Result<Data, POSIXError>]`, plus
  `waitForDeliveries(count:)`) in `TestUtilities.swift` is the receiver the TCP and QUIC transport
  tests pass to `connect`. In the QUIC tests the recorder is threaded through the helpers that
  actually connect (`connectedTransport(recorder:)`, `launchConnect(…, recorder:)`), defaulting
  to a fresh one; `makeTransport` / `makeGatedTransport` only construct and take no recorder.
- The TCP forwarding handler's zero-length-read and error paths cannot be produced on demand by
  a real socket, so the test target gains the `NIOEmbedded` product of swift-nio (test-only,
  Apple-platform-guarded like the other NIO products) and drives the handler through an
  `EmbeddedChannel`.
- `GatedOutcomeTransport` and `GatedConnectTransport` add the parameter and ignore it (they
  never deliver). `SMB2DisconnectReclaimTests` constructs `MockTransport(sendsAreDropped: true)`
  only to have a transport that never replies; it drops the argument.

### D7 — What the profiling metrics mean after the change

`TransportRead` and `InboundChunk` are now emitted back-to-back on the same thread, so the
script's "pump-hop latency" measures the in-callback hand-off (the `Data` copy already happened
before `TransportRead`; what remains is the bridge lock and the append) and the coalescing ratio
is 1.00 by construction — which holds only because the zero-length guard in D3 sits before the
`TransportRead` emit, so every `TransportRead` has a non-empty `InboundChunk` to pair with. The
one exception is teardown: `bridge.close()` sets `isClosed` synchronously and runs
`transport.close()` from a detached `Task`, so a read that lands in that window emits
`TransportRead` and is then dropped by `applyInbound` with no `InboundChunk`. That is at most a
trailing unpaired read at the very end of a recording, which the procedure document and the
gate in task 7.2 tolerate explicitly. `docs/PROFILING.md`'s metric table says so, and the before/after
section reads the delta from: cooperative-pool per-thread shares (the signature #45 targets),
`ServiceDispatch` and `ServicePass` percentiles, active throughput, stalls, and the residual
pump-hop row. The script and fixture are not touched: the metric definition (first paired read →
chunk) is unchanged, only its interpretation.

### D8 — Docs and release notes

`docs/API.md` shows the new protocol and adds a "Migrating a conformer from `receive()`"
snippet; `docs/ARCHITECTURE.md`'s inbound diagram and prose lose the pump task;
`AMSMB2/Signposts.swift`'s type comment ("two executor hops of the inbound pull loop") and the
`chunk(bytes:)` comment ("when the pump is behind …") are corrected; `docs/PROFILING.md`'s
"Using the baseline" step 3 names the post-conversion evidence (per-thread shares, dispatch and
pass percentiles, active throughput, stalls) instead of pump-hop latency and the coalescing
ratio. The `6.0.0-rc5` tag release notes carry the breaking-change entry and the migration
snippet — this repository's release notes live on tags.

*Spec coverage.* Delta specs: `transport-seam`, `transport-bridge`, `tcp-transport-apple`,
`quic-transport-apple`, `transport-connect-ordering` (the NEGOTIATE-ordering requirement and the
large-read requirement, whose body named "the inbound/outbound pumps"), `inbound-profiling`, and
`architecture-docs` (its Transport Layer requirement mandates coverage of "the inbound/outbound
pump tasks", which this change deletes). Purposes are outside the delta mechanism and are edited
directly in the main specs: `transport-bridge` ("both pump tasks"), `transport-seam`
("connect/send/receive/close", "loopback double") and `tcp-transport-apple`
("connect/send/receive/close … incremental inbound buffering"). `api-reference` needs no delta:
its requirement bodies name `SMBTransport` as a documented type but do not enumerate its
members. One scenario title in the `tcp-transport-apple` delta ("Inbound bytes are buffered for
incremental drain") is kept over a body that says the transport buffers nothing, because
`openspec validate --strict` refuses a MODIFIED block that drops a scenario name the main spec
has; the body states the real guarantee and the title is a historical label.

## Risks / Trade-offs

- [The handler now runs on the NIOTS event loop / NWConnection queue, so a slow bridge append
  delays the next network read] → The handler does one lock, one array append and one
  `eventLoopQueue.async`; the `Data` copy already happened on that queue before this change.
  Contention with `cRecv` on the bridge lock is the same pair of parties as today (append vs.
  drain), just from a different thread. Measured by the before/after gate; `ServiceDispatch`
  and `ServicePass` percentiles must not regress.
- [A conformer that keeps invoking the handler after `close()`] → The bridge ignores deliveries
  once closed (D2) and captures itself weakly, so an ill-behaved conformer cannot corrupt or
  retain it. In-tree conformers are held to D4 by tests.
- [Losing the "transport holds bytes until the pump starts" window] → The bridge FIFO holds them
  instead, and registering the inbound-ready handler fires the signal once if the store is
  already non-empty (D2), so nothing waits for a later delivery to wake it. Covered by the
  bridge test in task 2.1 that delivers (bytes, EOF, error in turn) before the handler is set,
  sets it, and asserts exactly one signal fired and `cRecv` returns the delivery.
- [Test churn in the two transport suites] → Mechanical: the QUIC helpers centralise most of it;
  each of the eight `receive()`-parking tests becomes a recorder assertion with the same
  scenario. The named scenarios in the QUIC and TCP specs are preserved one-for-one.
- [The delta may be small at this link speed] → Already known from the baseline (pump-hop median
  17 µs, ratio 1.00). The gate is "no regression, signature collapses", not a throughput target;
  the procedure document's reading rule spells that out.
- [Semver] → Must land before `6.0.0` final. RandomPlayer is pinned to rc4; the gate re-pins it
  to rc5.

## Migration Plan

1. Land the library, test and doc changes in one PR (full suite green, Linux target green,
   Samba integration suite green through the NIO TCP transport).
2. Tag `6.0.0-rc5` with the breaking-change release notes; re-pin RandomPlayer; profile three
   runs per `docs/PROFILING.md`; record the "After" table and the delta; comment on #45.
3. Rollback: revert the PR before `6.0.0` final; nothing downstream depends on the push API until
   rc5 is adopted.
