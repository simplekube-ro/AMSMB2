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
  `count-offset`, not total; (c) `$0.baseAddress!` in the consumer would crash if `chunkSize==0`.

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
- Retain/release stays 1:1: block runs exactly once → one passRetained; 4 mutually-exclusive release
  sites (context==nil guard, isAbandoned guard, catch, success via takeRetainedValue). onCancel never
  touches cbPtr. Moving passRetained later only NARROWS the bridge-retain window.
- Pre-existing (NOT introduced): `async_await_pdu`'s `} catch {` brace at ~:1022 is under-indented
  (16 not 24 spaces) — same on HEAD. Don't attribute to the concurrency fix.
- Linux test-portability gotchas (test target only compiles once lib errors clear): `URLCredential`
  needs `#if !canImport(Darwin) import FoundationNetworking`; `NSEC_PER_SEC` is `Int` on Glibc →
  wrap `UInt64(...)`; `NSKeyedUnarchiver` secure-coding tests SIGTRAP on swift-corelibs-foundation →
  guard `#if canImport(Darwin)` (JSON Codable covers redaction cross-platform).
