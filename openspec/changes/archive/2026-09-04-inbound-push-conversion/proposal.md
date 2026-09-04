# Inbound push-conversion

GitHub issue: [#45](https://github.com/simplekube-ro/AMSMB2/issues/45). Gate: the Release-build
baseline from [#44](https://github.com/simplekube-ro/AMSMB2/issues/44), recorded in
`docs/PROFILING.md` (2026-09-04, Apple TV 4K, tvOS 26.6, AMSMB2 6.0.0-rc4).

## Why

Every inbound chunk today crosses three executors: the transport's own network queue, a
cooperative-pool `Task` that pulls it through `SMBTransport.receive()` into the bridge FIFO, and
`eventLoopQueue` where libsmb2 drains it. The middle hop is pure hand-off — the bytes are already
in process when it starts — and it is what spreads the inbound work across the unnamed
cooperative-pool threads in the streaming trace. The baseline measures that hop at a median of
16–17 µs per chunk (p95 ≤ 46 µs, max 8.8 ms) over ~6 200 chunks per 106 MB. Removing it needs a
breaking change to the public `SMBTransport` protocol, and 6.0 is still on its rc runway
(current tag `6.0.0-rc4`), so this is the last window before the change would have to wait for
7.0.

## What Changes

- **BREAKING** `SMBTransport`: `receive() async throws -> Data` is removed. `connect` gains the
  receiver: `connect(host:port:onReceive:)`, where `onReceive` is a `@Sendable` closure the
  transport invokes with `Result<Data, POSIXError>` for each inbound chunk, on its own serial
  delivery queue, in arrival order. Empty `Data` still signals graceful EOF; a failure is
  abnormal loss; both are terminal. A `connect` that throws never invokes its handler, and a
  rejected repeat `connect` never replaces the live one. `send(_:)` and `close()` are
  unchanged.
- `TransportBridge`: the inbound pump `Task` and its start API are deleted. The bridge hands its
  inbound handler to the transport at connect time; the handler appends to the FIFO (or records
  EOF / error) and fires the inbound-ready signal, on the transport's delivery queue. The
  reset-before-drain debounce, `cRecv`'s return precedence (closed → bytes → EOF → error →
  would-block), the cross-boundary gather, and the `passRetained`/`takeRetainedValue` lifetime
  contract are untouched. Registering the inbound-ready handler signals once if the store is
  already non-empty, so a delivery that lands before registration cannot be a lost wakeup.
  Deliveries that arrive after the bridge closed are ignored.
- `TCPTransportApple` / `QUICTransportApple`: forward each network-stack callback straight to the
  registered handler (zero-length reads are skipped, terminal deliveries happen at most once).
  Their internal receive buffers and parked-continuation plumbing go away. Delivery stops the
  moment `close()` begins.
- `MockTransport` (test target): push-shaped — tests inject inbound chunks, EOF and errors through
  it, and observe sent bytes on it. Its send-loopback and the `sendsAreDropped` flag are removed.
- Docs: `docs/API.md` (protocol, EOF convention, conformer migration note),
  `docs/ARCHITECTURE.md` (inbound path), `docs/PROFILING.md` (what the pump-hop row means after
  the conversion; the before/after section).
- Operator gate, after the code lands: tag `6.0.0-rc5`, re-pin RandomPlayer, capture three runs
  by the `docs/PROFILING.md` procedure, and record the delta against the rc4 baseline in the same
  document. The release notes on the tag document the `SMBTransport` break with the migration
  snippet (this repository keeps release notes on tags, as `6.0.0-rc4` did; there is no
  `CHANGELOG` file — the issue's "CHANGELOG documents the break" criterion is met there).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `transport-seam`: the protocol's inbound operation is a push handler supplied at connect, not
  an async `receive()`; `MockTransport` injects inbound data instead of looping sends back.
- `transport-bridge`: the inbound shim is fed by the transport's delivery callback — no inbound
  pump task; teardown cancels one pump task, not two, and ignores late deliveries.
- `tcp-transport-apple`: inbound bytes are pushed as they arrive on the NIO event loop; no
  incremental receive buffer, no receiver to unblock on close.
- `quic-transport-apple`: the receive requirement and the close requirement are restated for
  push delivery (no parked waiter, no buffered-chunk drain at close, no never-connected
  `receive()` case); the connect-claim requirement's post-ready failure scenario routes to the
  delivery handler.
- `transport-connect-ordering`: the "first inbound receive succeeds" scenario becomes "the first
  inbound delivery reaches the bridge".
- `inbound-profiling`: the `TransportRead`/`InboundChunk` pairing is redefined for the pushed
  path (it now measures the in-callback hand-off, and a coalescing ratio above 1 is no longer
  possible); the procedure document carries the before/after comparison.
- `architecture-docs`: the Transport Layer section describes the pushed inbound path and the
  outbound pump task instead of "the inbound/outbound pump tasks".

## Impact

- **Public API (breaking):** `SMBTransport.connect(host:port:)` → `connect(host:port:onReceive:)`;
  `SMBTransport.receive()` removed. External conformers must move their inbound delivery into
  the handler. The practical break is source compatibility for out-of-tree conformers only:
  the public `SMB2Manager` API has no injection point for a custom transport, so applications
  that only select a `SMBTransportKind` are unaffected. Ships in `6.0.0` (next rc).
- **Library files:** `AMSMB2/SMBTransport.swift`, `AMSMB2/TransportBridge.swift`,
  `AMSMB2/TCPTransportApple.swift`, `AMSMB2/QUICTransportApple.swift`, `AMSMB2/Context.swift`
  (seam install: no inbound pump start; teardown comment), `AMSMB2/SMBQUICCertificateProbe.swift`
  (its `connect` call passes a no-op handler), `AMSMB2/Signposts.swift` (doc comments only).
- **Test files:** `MockTransport.swift`, `SMBTransportTests.swift`, `TransportBridgeTests.swift`,
  `SMB2ServicingLoopTests.swift`, `TCPTransportAppleTests.swift`,
  `QUICTransportAppleTests.swift`, `SMB2DisconnectReclaimTests.swift` (constructs
  `MockTransport(sendsAreDropped:)`), plus the two throwaway conformers in
  `BridgeOwnershipHandoffTests.swift` and `SMB2CBDataLifetimeTests.swift`; a shared inbound
  recorder helper in `TestUtilities.swift`.
- **Not affected:** `cRecv`, the debounce (`consumeInboundReadySignal`/`beginServicePass`), the
  outbound pump, the signpost names and formats, `scripts/profile-summary.sh` and its fixture,
  the Linux (libsmb2 built-in socket) path, `NIOTSChannelOptions.maximumReceiveLength`
  ([#46](https://github.com/simplekube-ro/AMSMB2/issues/46) — sequenced after this change so the
  two deltas do not confound each other).
- **Non-goals:** inbound backpressure (neither the pull loop nor the push path applies any;
  unchanged), public injection of custom transports, Linux seam support.
- **Dependencies:** none for the library. The test target adds the `NIOEmbedded` product of
  the already-depended-on swift-nio package (Apple platforms only) to drive the TCP forwarding
  handler deterministically.

## Review

**Verdict:** APPROVED WITH CONDITIONS
**Reviewer:** project-architect
**Date:** 2026-09-04

The shape is right and I endorse it. Deleting the cooperative-pool hop by making the receiver a
parameter of `connect` (D1) is the correct call over the issue's `setReceiveHandler(_:)` sketch:
it removes the "bytes arrived with no handler" state from every conformer instead of documenting
a rule around it, and both in-tree conformers already deliver on a single serial queue
(`InboundBufferingHandler.channelRead/channelInactive/errorCaught` on the NIOTS event loop;
`QUICConnectionDriver.armReceive` + `stateUpdateHandler` on the driver's own `queue` — I verified
both are the same serial queue per instance, so "serial, in arrival order" is a guarantee the
conformers can actually make). The weak self-capture in D2 is right and necessary — bridge →
transport → closure → bridge would otherwise outlive the `userdata` retain that
`makeExternalTransport()` balances. Lock discipline holds: `deliverInbound` takes the same
`TransportBridge.lock` that `appendInbound` takes today, `cRecv` is still the only contender, and
because each `TCPTransportApple` owns its own `NIOTSEventLoopGroup` the new head-of-line blocking
on the NIO event loop is scoped to that one connection. `_onInboundReady` must keep firing
outside the lock; the debounce and `cRecv`'s return precedence are untouched, as claimed.

The conditions below are one false mechanism claim that hides a lost-wakeup class (C1), one
missing delta for a capability whose requirement text mandates what this change deletes (C2), one
concrete defect introduced by conflating "empty chunk" with EOF at the delivery boundary (C3),
and a set of contract and impact gaps. None of them change the shape of the design.

### Conditions (address before `/opsx:apply` completes; artifacts must reflect them)

1. **[High] D2's "the first service pass drains them" is false, and the window it dismisses is a
   new lost-wakeup class.** Verified against the code: `serviceContextForSeam` is the *only* path
   that ORs `POLLIN` (`Context.swift:1849`), and its own doc comment says it is called
   exclusively from the bridge's inbound-ready callback. `flushOutboundForSeam`
   (`Context.swift:1869`) calls `smb2_service(context, POLLOUT)` only, and the timer work item
   (`Context.swift:1913`) calls `smb2_service_timeout` then `flushOutboundForSeam` — neither
   reads. In libsmb2, `smb2_service` reads only under `if (revents & POLLIN)` (`lib/socket.c`).
   So a chunk that lands in the FIFO with no `_onInboundReady` registered is drained only when a
   *later* delivery signals; if it is the last chunk, the connect hangs to the operation timeout.
   The claim that this is "the same window and the same behaviour as today" is also wrong:
   today `startPumps()` runs *after* `setInboundReadyHandler` in the same install block
   (`Context.swift:1666` then `1728`), so every append has always signalled.
   Required: (a) correct the D2 paragraph and the `transport-bridge` MODIFIED requirement text
   (which currently asserts the same false mechanism in "they are drained by the first service
   pass"); (b) close the window in code — `setInboundReadyHandler` SHALL fire the handler once,
   outside the lock, when the store is already non-empty or holds EOF/an error at registration
   time; (c) record in D2 the ordering invariant that makes the window rare rather than routine
   (no outbound byte can leave before registration, because the outbound pump is started after
   it), so a future reordering of `connectWithBridge` is visibly load-bearing; (d) add a bridge
   test that registers the handler *after* a delivery and asserts the signal fires on
   registration — the currently planned test in task 2.1 only asserts `cRecv` returns the bytes,
   which passes even with the wakeup lost.

2. **[High] Missing `architecture-docs` delta; three more spec texts go stale.** The
   `architecture-docs` requirement "Transport layer (Apple seam) documentation" mandates that the
   document cover "the **inbound/outbound pump tasks** with copy-at-the-C-boundary semantics" —
   task 5.1 deletes exactly that from `docs/ARCHITECTURE.md`, so the capability needs a MODIFIED
   delta (faithful full copy, only that clause edited). Also required, in the same pass:
   `openspec/specs/transport-seam/spec.md` Purpose ("async connect/send/receive/close" and
   "in-memory **loopback** double") and `openspec/specs/tcp-transport-apple/spec.md` Purpose
   ("connect/send/receive/close with cancellation and incremental inbound buffering") edited
   directly, exactly as D8 already plans for the `transport-bridge` Purpose; and
   `transport-connect-ordering`'s "Large read and write round-trip through the seam" requirement,
   whose body says "exercising the inbound/outbound pumps" — either a MODIFIED delta or a
   one-line justification in design.md for why it still reads true. `api-reference` needs no
   delta (its requirement bodies name `SMBTransport` as a type but do not enumerate its members)
   — state that conclusion in design.md so `/opsx:verify` does not have to re-derive it.

3. **[High] A zero-length inbound read would be misread as EOF.** Today `appendInbound`
   (`TransportBridge.swift:478`) silently skips an empty `Data` and `setInboundEOF` is a separate
   entry point, so an empty `channelRead` is harmless. Under D3, `channelRead` "copies the
   `ByteBuffer` to `Data` … and forwards `.success(data)`" unconditionally, and `deliverInbound`
   treats `.success(empty)` as terminal EOF — a spurious EOF tears the connection down. Required:
   `InboundForwardingHandler.channelRead` SHALL return early on a zero-length read *before*
   emitting `TransportRead` and before forwarding (QUIC's `armReceive` already guards with
   `if let content, !content.isEmpty` — match it). Note this in D3 and in the D7 profiling
   paragraph: with the guard, "every `TransportRead` pairs with exactly one `InboundChunk`" is
   true by construction; without it the pairing claim in the `inbound-profiling` delta is an
   overclaim.

4. **[Medium] Specify the handler install against the one-shot connect reservation, and the
   failed-connect contract.** Making the handler a `connect` parameter means every *rejected*
   `connect` call also carries one. Both conformers reserve their single attempt in the first
   lock-protected section (`TCPTransportApple.swift:202`, and QUIC's mirror), so the closure
   SHALL be installed only after that reservation succeeds — otherwise a second `connect`
   returning `EALREADY`/`EISCONN` clobbers the live receiver and inbound bytes vanish silently.
   Add this to D3/D4, to the `tcp-transport-apple` one-shot requirement (its "Connect after an
   established connection is rejected" scenario should assert the first receiver still receives),
   and to task 3.2/4.2. Separately, state in the `transport-seam` protocol requirement — not only
   in the MockTransport scenario — that a `connect` which throws never invokes its handler.

5. **[Medium] The outbound pump's `setInboundError` call site is unaccounted for.** Task 2.2
   deletes `setInboundError`, but it has a second caller: `outboundPump()` on a `transport.send`
   failure (`TransportBridge.swift:375`). Say explicitly that it becomes
   `deliverInbound(.failure(error))`, and decide-and-record whether `deliverInbound` enforces
   terminal-once bridge-side. My recommendation is **no** bridge-side terminal flag: the only
   guard stays `isClosed`, so `cRecv`'s bytes → EOF → error precedence stays byte-for-byte
   identical to today (goal 3 of the design). Terminal-once is then a conformer obligation, which
   is what the specs already say — make that split explicit in D2.

6. **[Medium] QUIC terminal-once needs one flag, and it must cover EOF.** `handleFailed`,
   `handleCancelled` and `handleReceive(.failure)` each guard on `lifecycle == .active`, but
   `handleReceive`'s empty-`Data` EOF branch does **not** touch `lifecycle`
   (`QUICTransportApple.swift:625-633`) — so a peer EOF followed by the routine `.cancelled`
   would deliver a failure *after* a terminal delivery, violating the new contract and the
   delta's own "nothing is delivered after either" and "Exactly-once … across teardown races"
   scenarios. Required: a single lock-guarded `deliveryTerminated` flag, checked and set in all
   four producers (EOF, chunk-path failure, post-ready `.failed`, post-ready `.cancelled`) and in
   the `open → closing` transition; name it in D3/D4 and in task 4.2, and add the EOF-then-cancel
   ordering to task 4.1's scenario list.

7. **[Medium] Decide the `Result` failure type against Swift 6 on Linux.** `AMSMB2/SMBTransport.swift`
   and `AMSMB2Tests/MockTransport.swift` are **not** guarded by `#if canImport(Network)` — they
   compile on Linux, where `swift:6.1` hard-errors on sends that macOS only warns about. `MockTransport`
   stays an `actor` (D6) and will invoke a `@Sendable (Result<Data, any Error>) -> Void` from
   actor-isolated code with a non-`Sendable` `any Error` payload it also stores. D1's rejection of
   `POSIXError` ("the bridge stores `any Error`") does not weigh this. Either adopt
   `Result<Data, POSIXError>` (trivially `Sendable`, matches the CLAUDE.md "no custom Error types"
   convention and what `QUICConnectionDriver.start` already uses) or keep `any Error` and record
   in D1 that the actor-conformer send was verified under `-strict-concurrency=complete` on
   Linux. Either way task 4.3's `make linuxtest` is the gate, and the design should say so.

8. **[Medium] Two missed call sites in the Impact list.**
   `AMSMB2Tests/SMB2DisconnectReclaimTests.swift:193` constructs
   `MockTransport(sendsAreDropped: true)` and is in neither the proposal's test-file list nor any
   task — deleting the flag breaks the build. `AMSMB2/SMBQUICCertificateProbe.swift:159` calls
   `transport.connect(host:port:)` and must pass a no-op handler; task 4.2 covers it but the
   proposal's "Library files" list omits it. Add both, and add
   `SMB2DisconnectReclaimTests.swift` to a task (the mock there needs no injection — dropping the
   argument is sufficient once the loopback is gone).

9. **[Low] Precision and staleness items.** (a) The `tcp-transport-apple` delta keeps the scenario
   title "Inbound bytes are buffered for incremental drain" over a body that says the transport
   buffers nothing — retitle (e.g. "Every chunk is delivered as it arrives"). (b)
   `AMSMB2/Signposts.swift`'s type doc ("the two executor hops of the inbound pull loop", "the
   `TransportRead → InboundChunk` gap is the cooperative-pool pump hop") and `chunk(bytes:)`'s
   comment ("When the pump is behind, several `TransportRead`s coalesce") go stale; task 4.3's
   grep sweep does not catch them — add the file to task 5.2. (c) `docs/PROFILING.md`'s "Using
   the baseline" step 3 still names pump-hop latency and the coalescing ratio as "the evidence
   the PR must carry" — task 5.2 must update it alongside the Metrics table. (d) D3 says the
   *channel initializer* installs the closure while task 3.2 says *`connect`* does; `inboundHandler`
   is a stored `let`, so `connect` (after condition 4's reservation) is correct — align D3. (e) The
   `quic-transport-apple` delta silently drops "; tasks 2.5" from an unrelated sentence; restore
   it or note the cleanup.

10. **[Low] Mark the compile-time-only scenario as such.** `transport-seam`'s "Connection cannot
    exist without a receiver" is a structural property no runtime test can fail. Per this
    repository's convention for untestable production wiring, add a NOTE to the requirement
    saying it is verified by the compiler and code inspection, so `/opsx:verify` does not look for
    a test that cannot exist.

### Verified, no action needed

- The `Unmanaged` lifetime contract is untouched: `makeExternalTransport()`'s single
  `passRetained` is still consumed exactly once in the C `close` trampoline, and the weak capture
  in D2 means the transport's closure can outlive the bridge without a dangling reference.
- Reachability of the D5 change: `startPumps()` has exactly one production call site
  (`Context.swift:1728`); `startOutboundPump()` slots in unchanged, still after the handler
  registration.
- No lock inversion is introduced: nothing in the bridge calls back into the transport while
  holding `TransportBridge.lock` (`close()` fires `transport.close()` from a detached `Task`),
  and D3's "read the closure under the conformer's lock, invoke it outside" keeps the conformer
  side clean.
- `scripts/profile-summary.sh`, its fixture, the five signpost names/formats and the
  `inbound-profiling` "Trace summary tooling" requirement stay valid — the metric definition is
  unchanged, only its interpretation, as D7 claims.
- Semver and rollout are right: `6.0.0-rc4` is the current tag, no public injection point for a
  custom transport exists yet, and tag release notes are this repository's changelog. Worth one
  sentence in Impact that the practical break is source-compatibility for out-of-tree conformers
  only.

### Re-gate 1 (2026-09-04) — APPROVED WITH CONDITIONS (one residual)

**Verdict:** APPROVED WITH CONDITIONS
**Reviewer:** project-architect
**Date:** 2026-09-04

Verified against the files, not the summary. Nine of the ten conditions are fully closed; one
line of design.md still carries the claim condition 1 retracted. That residual (R1) is editorial
— it changes no decision, no spec and no task — so it does **not** need another re-gate: fix it
in the apply pass and `/opsx:verify` confirms it. `openspec validate --changes --strict` passes
(1 passed, 0 failed).

**R1 — [Low, must fix in the apply pass] design.md's Risks bullet still asserts the retracted
mechanism.** `design.md:271`: "The bridge FIFO holds them instead; **the first service pass
drains them**. Covered by an explicit test (deliver before the inbound-ready handler is set, then
set it, then verify `cRecv` returns the bytes)." That is the exact claim condition 1 required
removed, and the test it describes is the weaker one that task 2.1 replaced. Rewrite the bullet
to match D2 and task 2.1: the bridge FIFO holds them and registering the inbound-ready handler
fires the signal once, covered by the test that asserts the signal count (not only the bytes).
Nothing else in the change repeats the claim — `grep -rn "first service pass"` finds only this
line and the round-1 finding text above.

### Condition-by-condition

1. **Closed (with R1 above).** D2 now states the verified mechanism — `serviceContextForSeam` is
   the only `POLLIN` path, `flushOutboundForSeam` is `POLLOUT`-only, the timer reads nothing —
   and closes the window in `setInboundReadyHandler` (store the handler under the lock, invoke it
   once outside the lock if the store already holds bytes/EOF/error). The ordering invariant
   (outbound pump started after registration, so no NEGOTIATE leaves before it) is recorded and
   task 2.2 puts a comment at the `Context.swift` call site. The `transport-bridge` requirement
   text carries both halves, and the two scenarios ("Delivery before the ready handler is
   registered is not lost" now asserts *exactly one signal at registration*; "Registration with an
   empty store does not signal") pin the boundary in both directions. Task 2.1 asserts the signal
   count and calls out that this is the lost-wakeup test.
2. **Closed.** `specs/architecture-docs/spec.md` is a faithful full copy of the main requirement
   with only the pump-tasks clause edited (diffed; scenarios byte-identical). The
   `transport-connect-ordering` delta gained the "Large read and write round-trip" requirement
   ("exercising the pushed inbound path, the outbound pump and the no-fd servicing loop"). Task
   5.1 edits the `transport-seam` and `tcp-transport-apple` Purposes alongside `transport-bridge`,
   and D8's "Spec coverage" paragraph records the `api-reference` no-delta conclusion with its
   reason.
3. **Closed.** D3 puts the zero-length early return before the `TransportRead` emit and before the
   forward, with the "empty `Data` means EOF" rationale and the QUIC `!content.isEmpty` precedent;
   the tcp requirement text and the new "Zero-length read is not EOF" scenario state both halves
   (no delivery, no signpost); the `inbound-profiling` delta says zero-length reads are skipped
   before the event, which is what makes the 1.00 pairing claim true rather than an overclaim;
   D7 now says so explicitly; tasks 3.1/3.2 cover it, including an `EmbeddedChannel`-style
   direct-`channelRead` test.
4. **Closed.** D1's "Failed and rejected connects" paragraph, the `transport-seam` requirement
   text ("a `connect` that throws SHALL never invoke its handler" plus the rejected-repeat rule)
   with the "Failed connect never delivers" scenario, the tcp `EISCONN` scenario extended with
   "the first call's handler, not the rejected call's, keeps receiving", and the QUIC "Rejected
   repeat connect keeps the first receiver" scenario. Tasks 3.1/3.2/4.1/4.2 all carry it.
5. **Closed.** `applyInbound` is named as the shared private path, `outboundPump()`'s send failure
   is explicitly routed through it, and the "No bridge-side terminal-once" paragraph plus the
   matching sentence in the `transport-bridge` requirement fix the split I asked for (only
   `isClosed` guards; `cRecv` precedence unchanged; terminal-once is the conformer's obligation).
   Task 2.1 tests the send-failure precedence.
6. **Closed.** One lock-guarded `deliveryTerminated` flag across the four producers and the
   `open → closing` transition, with the EOF-does-not-move-`lifecycle` rationale in D3; the QUIC
   requirement text and the "EOF followed by a later state event delivers nothing" scenario;
   tasks 4.1/4.2.
7. **Closed, and the stronger choice.** `Result<Data, POSIXError>` throughout (protocol, bridge,
   `InboundRecorder`, mock). D1 records the reason — `SMBTransport.swift` and `MockTransport.swift`
   are unguarded and compile on Linux, where 6.1 hard-errors on a non-`Sendable` `any Error`
   leaving the actor — and it matches `QUICConnectionDriver.start(onReceive:)` and the
   `POSIXError`-only convention. Task 4.3 names `make linuxtest` as the gate for exactly this.
   Note the internal asymmetry is handled: the outbound-pump send error stays `any Error` in the
   bridge's own store, which is correct — only the seam payload is typed.
8. **Closed.** `SMBQUICCertificateProbe.swift` and `Signposts.swift` are in the library-file list,
   `SMB2DisconnectReclaimTests.swift` in the test-file list, and tasks 1.2 and 4.2 name the two
   edits.
9. **Closed.** (a) The kept scenario title is justified — `openspec validate --strict` refuses a
   MODIFIED block that drops a scenario name the main spec has, and there is no rename mechanism;
   recording that in D8 is the right resolution, and the body carries the real guarantee. (b)/(c)
   `Signposts.swift`'s comments and PROFILING's "Using the baseline" step 3 are in task 5.2, with
   a `grep -n "pump" AMSMB2/Signposts.swift` check. (d) D3 now says `connect` installs the closure
   after the reservation, matching task 3.2. (e) "; tasks 2.5 of the QUIC change" restored.
10. **Closed.** The NOTE on "Connection cannot exist without a receiver" names the compiler and
    inspection as the verification, so `/opsx:verify` will not hunt for an impossible test.

No new findings. The added scenarios do not contradict anything in the untouched requirements,
the delta blocks still diff clean against the main specs apart from the intended edits, and
nothing in the revision changes the thread-safety, `Unmanaged` lifetime or `cRecv` precedence
conclusions recorded in round 1.
