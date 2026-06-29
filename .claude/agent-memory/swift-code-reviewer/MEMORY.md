# AMSMB2 — swift-code-reviewer memory

## Build/test (sandbox)
- `swift build --disable-sandbox` / `swift test --disable-sandbox` (plain `make test` fails in sandbox).
- Force-surface warnings: `touch` changed files then rebuild (build is heavily cached, 0.5s no-op).
- Unit suite ~144 tests, ~50 integration skipped without `SMB_SERVER`. Seam acceptance needs Docker:
  `docker-compose -f test-fixtures/docker-compose.yml up -d`, wait `nc -z 127.0.0.1 445`, run with
  `SMB_TRANSPORT=seam SMB_SERVER=smb://127.0.0.1 ...`, ALWAYS `down -v` after.

## Pre-existing warnings (do NOT attribute to new changes)
- `Context.swift` ~lines 874/879/967/972: `#SendableClosureCaptures` on the legacy `async_await`
  generic helpers (cbPtr / handler captures). All 4 are pre-existing on the legacy path. Verify any
  reported warning's line is OUTSIDE the diff hunks before flagging.

## AsyncInputStream premature-EOF — FIXED (fix-stream-premature-eof)
- Was: `read()` flipped `.atEnd` on any buffer drain → truncated streamed uploads at the prefetch
  window (~5 MiB). Fix: `producerFinished` flag (set under `bufferLock` only when iterator returns
  `nil`); `read()` returns `0`/`.atEnd` only when drained AND `producerFinished`, else `-1`
  would-block (status left `.open`). Consumer `write(client:from:toPath:)` classifies `-1`:
  `.open/.reading`+no error → `Task.yield()` retry; `.error` → throw `streamError`; other → break.
  G1: `prefetchData()` catch now stores `_streamError` (was always nil). Removed dead
  `InputStream.readData(maxLength:)`. Verified: full seam suite 148/0, stream test x8 all complete
  to full size >5 MiB.
- Non-blocking residuals to watch in future changes (NOT introduced by this fix):
  (a) consumer `Task.yield()` retry is a busy-poll — fine for file-backed producers, can spin-burn
  CPU for a slow generic `AsyncSequence`; (b) `buffer` Data grows to the FULL stream size
  (`bufferOffset` only advances, consumed prefix never freed) — backpressure bounds only
  `count-offset`, not total; (c) `$0.baseAddress!` was replaced by `guard let base ... else
  { return 0 }` — now silently reports EOF (success, empty file) if `chunkSize==0` rather than
  crashing; chunkSize is `>0 ? : optimizedWriteSize` so dead in practice, but silent-loss shape.
- 4.1 REVIEW FINDING (should-fix, low-probability): this fix makes `_streamError` the FIRST
  cross-thread-mutable field (was always-nil/effectively-const pre-fix — confirmed via git). Prefetch
  writes `_streamError`+`_streamStatus=.error` UNDER bufferLock, but the new consumer classification
  in `write(...)` reads `stream.streamStatus` (3x) + `stream.streamError` (2x) ALL UNLOCKED, and the
  `streamError`/`streamStatus` computed getters read the backing vars without the lock. Violates the
  project's own "every read of `_streamError` under bufferLock" rule. A torn read (status `.error`
  visible, `_streamError` not) surfaces `POSIXError(.EIO)` instead of the real error → defeats G1.
  Fix: one locked snapshot consumed once per classification, e.g. `func statusSnapshot() ->
  (Stream.Status, (any Error)?) { bufferLock.withLock {(_streamStatus, _streamError)} }`. The bare
  `_streamStatus` unlocked reads are pre-existing (open/close/switch); the change only makes them
  newly load-bearing for the error path. Build clean, 0 new warnings on changed files.
- 4.1 VERIFY PASS (working tree, pre-commit): finding-1 fixed via `statusSnapshot() ->
  (Stream.Status,(any Error)?)` = `bufferLock.withLock {(_streamStatus,_streamError)}` + an internal
  marker protocol `StreamStatusSnapshotting` (AsyncInputStream conforms) so the `InputStream`-typed
  consumer does `(stream as? any StreamStatusSnapshotting)?.statusSnapshot() ?? (stream.streamStatus,
  stream.streamError)`. SOUND + simplest viable: generic param can't be cast away and you can't
  override a stdlib-class method via extension, so `as?`-to-protocol is the idiomatic erasure. No
  orphans (1 conformer, 1 call site + 1 test). Fallback is safe: the consumer is also fed plain
  `InputStream(data:)` (1099/1153) & `InputStream(url:)` (1338/1347) — synchronous stdlib streams
  set status/error on the same thread before `read` returns -1, nothing to tear. Finding-2:
  `precondition(chunkSize>0)` + `guard let base ... else { return -1 }` (was `return 0`) — makes the
  -1 unreachable and kills the silent-empty-success shape. VERDICT APPROVED: build 0 warnings; test
  158 exec / 51 skip / 0 fail; 5/5 AsyncInputStreamTests. Minor (noted, non-blocking):
  `precondition` traps in release vs throwing EINVAL — defensible (chunkSize==0 = internal invariant
  breach from negotiated optimizedWriteSize, not user input).

## Marker-protocol erasure for generic InputStream subclass (REUSABLE PATTERN)
- To call a method on a generic `InputStream` subclass (`AsyncInputStream<Seq>`) from code holding a
  base `InputStream`: you canNOT spell/cast the generic param, and you canNOT override a stdlib-class
  method via Swift extension. Solution: declare a non-generic `protocol P { func f() -> ... }`,
  `extension AsyncInputStream: P {}`, then `(stream as? any P)?.f() ?? <plain-stream fallback>`.
  Keep P internal even though the class is public (conformance is internal — fine).

## Transport seam architecture (Apple = seam-only after T9)
- Apple routes ALL connections through the NIO seam (`TransportBridge` + `TCPTransportApple`).
  Legacy libsmb2 built-in TCP (`SocketMonitor`/`pollUntilComplete`/`connect(server:share:user:)`)
  is `#if !canImport(Network)` — Linux only. Guard-not-delete (Linux is sole consumer).
- Seam connection owns NO native fd: `smb2_get_fd == -1` always. So connectivity predicates MUST use
  the seam-aware `isConnected` (checks `seamConnected` flag), never `fileDescriptor != -1`.
- Naming trap: seam uses `smb2_set_transport(ctx, SMB2_TRANSPORT_AUTO, ext)` (==2), NOT `_TCP` (==0,
  selects libsmb2's built-in socket and ignores ext).
- `TransportBridge` lifetime: `makeExternalTransport()` does `Unmanaged.passRetained(self)` into
  `ext.userdata`, consumed exactly once by `takeRetainedValue()` in the C close trampoline.
  `bridge.close()` touches ONLY transport/pumps — it does NOT change the Unmanaged refcount, so
  early-failure paths call BOTH `bridge.close()` AND `Unmanaged.release()` with no double-release.

## Connect-ordering fix (fix-seam-connect-ordering, Approach A "eager connect")
- Root cause was: old `kickConnect` fired `Task { try? await connect }` (detached, swallowed) and
  returned 0 → libsmb2 `ext_connect` treats 0 as "connected" and fires NEGOTIATE into a nil channel
  → ENOTCONN(57) → mapped to EPERM via -(-1)=1.
- Fix: `connectWithBridge` `await`s `bridge.connect(host:port:)` on the CALLER's task (never on
  `eventLoopQueue` — that would block the single serial queue) BEFORE `smb2_set_transport`. The C
  `ext.connect` trampoline becomes a state reporter: `connectStatus()` returns `isPreConnected ? 0
  : -ECONNREFUSED`, performs NO second connect (double-connect would open 2 channels).
- `TCPTransportApple.connect` self-cleans its channel on cancel/failure, so the eager-connect THROW
  path needs no `bridge.close()` (nothing live). Mandate to close applies only AFTER a successful
  connect (the `context == nil` and `smb2_set_transport != 0` guards — both correctly close).
- `parseSeamEndpoint` mirrors libsmb2 `ext_connect` byte-for-byte: `[ipv6]`, first-`:` split,
  default 445, strtol-style leading digits, missing `]` -> EINVAL. Unit-test table pins it.

## Seam teardown-ordering invariant (fix-seam-connect-ordering, P1/P2 review fixes) — CONFIRMED
- `connectWithBridge` timeout (asyncAfter ~:1297) and cancel (onCancel ~:1313) both do
  `removeValue` + `teardownSeam()` BEFORE `continuation.resume(...)`, all in ONE serial
  `eventLoopQueue.async` block. So `pendingSeamOperationCount` (Apple-only, Context.swift ~:539,
  `syncOnEventLoop { pendingOperations.count }`) read from a test thread AFTER the awaited op throws
  is GUARANTEED 0 (serial-queue happens-before; sync read runs after the resuming block returns).
  `seamConnected` likewise false before resume → `isConnected` false. Makes the unit asserts
  deterministic. Empirically: timeout test ~0.316s, cancel test ~0.083s, stable x3.
- Timeout determinism: `timeout:0.3` → Swift asyncAfter 0.3s vs libsmb2 floor `max(1,ceil)=1s`
  (smb2_set_timeout). 0.7s margin; serial queue dequeues earlier deadline first; teardownSeam
  cancels `pendingTimeoutItem`. Cancel determinism: 30s timeout + MockTransport(sendsAreDropped)
  → only onCancel resumes → always CancellationError; `if cb.isAbandoned` fast-path (~:1268) covers
  the store-vs-onCancel race.
- `TCPTransportApple` is SINGLE-USE: fresh instance per production connect (Context.swift:1079).
  `_connectCancelled`/`_connectingChannel` per-connect, guarded by `lock`, channel ALWAYS closed
  OUTSIDE `withLock`. Initializer-vs-onCancel race closes the channel exactly once in BOTH lock
  orderings; NIO `close(promise:nil)` is idempotent (double-close safe). Latent gap (NOT triggered
  by seam — connect fully completes before any close()): `close()` during a pending connect won't
  close `_connectingChannel`; backstopped by `group.shutdownGracefully()`. `_connectCancelled` is
  never reset — fine for single-use, would mis-fire on instance reuse.
- `mapTransportConnectError` (Context.swift:1141): POSIXError/CancellationError pass through, else
  wrapped `POSIXError(.ECONNREFUSED)` → eager-connect failures always surface as POSIXError.

## CBData ownership contract (fix-cbdata-cancel-race-uaf) — VERIFIED against libsmb2 source
- `generic_handler` (Context.swift ~861) calls `takeRetainedValue()` BEFORE the `guard !isAbandoned`
  (line ~862). So it MUST fire EXACTLY ONCE per cbPtr — double-fire over-releases → UAF; a manual
  `.release()` after the PDU is queued double-balances → UAF.
- RULE: after `smb2_*_async`/`smb2_queue_pdu` SUCCESS (PDU queued), NEVER `Unmanaged.release()` the
  cbPtr. libsmb2 owns it and fires generic_handler once: on reply (smb2_service) OR during
  `smb2_destroy_context` (init.c:323-351 sweeps outqueue/pdu/waitqueue, fires every pdu->cb with
  SMB2_STATUS_SHUTDOWN). Cancel/timeout/onCancel ABANDON (set isAbandoned + resume) WITHOUT releasing.
  PRE-queue sites (context==nil guard, the `catch` after a throwing setup call, smb2_set_transport!=0,
  connectResult<0, legacy connect result<0) MUST still release — libsmb2 never took ownership there.
- Connect chain (seam): `smb2_connect_share_async(...,generic_handler,cbPtr)` → c_data->cb=generic_handler
  → `smb2_connect_async` → `ext_connect` (transport-external.c:147) fires internal `connect_cb`
  SYNCHRONOUSLY (queues NEGOTIATE w/ negotiate_cb→c_data) then NULLS `smb2->connect_cb`. At destroy:
  outqueue sweep fires negotiate_cb(SHUTDOWN)→c_data->cb=generic_handler ONCE + free_c_data; the later
  `if(smb2->connect_cb)` is NULL → skipped. No double-fire. So connectWithBridge's abandoned branch
  correctly KEEPS teardownSeam() and drops the release.

## Deterministic post-queue-cancel test (SMB2CBDataLifetimeTests) — PROVEN non-vacuous
- Gated actor transport whose `connect` parks on `CheckedContinuation<Void, Never>` (NON-throwing —
  returns normally even when cancelled). waitUntilConnecting → task.cancel() → openGate. connect
  returns normally → connectWithBridge enters an ALREADY-cancelled `withTaskCancellationHandler`: the
  onCancel block enqueues to the serial eventLoopQueue SYNCHRONOUSLY (before the operation block) →
  sets isAbandoned ahead of the setup block → setup block hits the post-queue abandoned branch.
- To VERIFY a UAF-regression test: temporarily restore the old `.release()`, run
  `swift test --disable-sandbox --sanitize=address --filter <test>` → expect
  `heap-use-after-free ... Context.swift:862 in generic_handler` (signal 6); fixed code passes ASan
  clean. (Proven in this review: old=crash@862, new=pass.) Without ASan the freed access may not crash.
- Capture `[client]` BY VALUE in the driving `Task` (Swift 6 forbids capturing a mutable `var` in a
  @Sendable closure); after `task.value` that copy releases so a later `client = nil` is the last ref
  → deterministic deinit→smb2_destroy_context. SMB2Client/TransportBridge are @unchecked Sendable;
  SMBTransport is a `Sendable` protocol (actor conforms cleanly).

## Conventions confirmed
- Errors: `POSIXError(.CODE)` only, no custom Error types. 4-space indent, 100/132 width, MIT header.
- No `NSLock.lock()` in async bodies — wrap in a synchronous helper (e.g. `markPreConnected()`).
- No `await` inside `withUnsafeBytes`/`withCString`; copy C buffers synchronously (design D4).

## Swift 6.1 Linux strict-concurrency (fix-swift6-concurrency) — CONFIRMED PATTERN
- `swift:6.1` Linux promotes this module's strict-concurrency *warnings* to hard *errors*; Apple
  toolchain keeps them warnings. Dockerfile is `FROM swift:6.1`; verify Linux via `make linuxtest`.
- The 5 pre-existing Context.swift sites: `queueKey` static (DispatchSpecificKey not Sendable on
  Linux), + cbPtr/handler captures in `async_await`/`async_await_pdu` legacy runners.
- Fix pattern (mirrors `connectWithBridge`): (1) construct `cbPtr =
  Unmanaged.passRetained(cb).toOpaque()` LOCAL inside the `eventLoopQueue.async` block (no annotation
  needed — only Sendable `cb`/`cbId` cross the boundary); (2) `nonisolated(unsafe) let
  confinedHandler = handler` at FUNCTION scope (not inside block, else capture isn't laundered),
  call `confinedHandler(...)`; (3) `queueKey` needs `#if canImport(Darwin)` split — bare
  `nonisolated(unsafe)` triggers a NEW "'nonisolated(unsafe)' is unnecessary" warning on Apple.
- Retain/release stays 1:1: block runs exactly once → one passRetained. onCancel never touches
  cbPtr. Moving passRetained later only NARROWS the bridge-retain window. (UPDATE: the old
  "isAbandoned guard" release site was REMOVED by fix-cbdata-cancel-race-uaf — see the CBData
  ownership contract section. Post-queue release sites are now ONLY: context==nil guard + the
  pre-queue `catch`. The abandoned branch ABANDONS without releasing; success balances via
  generic_handler's takeRetainedValue.)
- Pre-existing (NOT introduced): `async_await_pdu`'s `} catch {` brace at ~:1022 is under-indented
  (16 not 24 spaces) — same on HEAD. Don't attribute to the concurrency fix.
- Linux test-portability gotchas (test target only compiles once lib errors clear): `URLCredential`
  needs `#if !canImport(Darwin) import FoundationNetworking`; `NSEC_PER_SEC` is `Int` on Glibc →
  wrap `UInt64(...)`; `NSKeyedUnarchiver` secure-coding tests SIGTRAP on swift-corelibs-foundation →
  guard `#if canImport(Darwin)` (JSON Codable covers redaction cross-platform).
