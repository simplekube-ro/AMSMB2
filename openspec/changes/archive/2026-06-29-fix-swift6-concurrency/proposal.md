## Why

The Linux CI image was bumped to `swift:6.1` (the Dockerfile now reads `FROM swift:6.1` and the
stale `COPY Package@swift-6.0.swift` line was removed). Under Swift 6.1 the package **fails to
build on Linux** with five strict-concurrency diagnostics in `AMSMB2/Context.swift`. On macOS these
same diagnostics are emitted as *warnings* (the toolchain there still treats this module's
strict-concurrency findings as non-fatal), so the Apple build is green and the debt went unnoticed;
on Swift 6.1 they are **hard errors** and the Linux build never compiles or runs its tests.

All five pre-exist on `master` — they are **not** introduced by the transport-seam work. They live
in code that long predates the seam: the static re-entrancy key and the two legacy generic operation
runners (`async_await(execute:)` / `async_await_pdu(execute:)`) that drive *every* libsmb2 operation
on both platforms. The seam path already solved the identical `cbPtr`-capture problem the right way
(see `connectWithBridge`); this change retro-fits that same, proven pattern onto the legacy runners
and clears the one remaining non-`Sendable` static.

### The five diagnostics (all `AMSMB2/Context.swift`)

1. **:107** `static let queueKey = DispatchSpecificKey<Bool>()` — `DispatchSpecificKey` is not
   `Sendable`, so a `static` of that type is "not concurrency-safe".
2. **:874** capture of `cbPtr` (`UnsafeMutableRawPointer`, non-`Sendable`) in the `@Sendable`
   `eventLoopQueue.async` closure inside `async_await(dataHandler:execute:)`.
3. **:879** capture of `handler` (`UnsafeContextHandler<Int32>`, a non-`Sendable` closure) in the
   same `@Sendable` closure.
4. **:967** capture of `cbPtr` in the `@Sendable` closure inside `async_await_pdu(dataHandler:execute:)`.
5. **:972** capture of `handler` (`UnsafeContextHandler<smb2_pdu?>`) in that same `@Sendable` closure.

## What Changes

- **Local pointer construction (errors 2 & 4).** Move the `Unmanaged.passRetained(cb).toOpaque()`
  call **inside** the `eventLoopQueue.async` block in both `async_await(dataHandler:execute:)` and
  `async_await_pdu(dataHandler:execute:)`, so `cbPtr` becomes a block-local `let` instead of a value
  captured across the `@Sendable` boundary. Only the `Sendable` `cb` (`CBData` is `@unchecked
  Sendable`) and `cbId` (`ObjectIdentifier`) are captured. This is exactly the pattern already used
  by `connectWithBridge` (`Context.swift:1159–1161`, "Construct the opaque pointer locally to avoid
  capturing a non-`Sendable` `UnsafeMutableRawPointer` across the `@Sendable` closure boundary").
- **`nonisolated(unsafe)` for the operation handler (errors 3 & 5).** The `handler` parameter is a
  non-`Sendable` closure that *must* cross into the `@Sendable` block to be invoked there. It is only
  ever called on `eventLoopQueue` (the serial queue that exclusively owns the `smb2_context`), so its
  effective isolation is the queue. Launder it with a block-/function-local `nonisolated(unsafe)`
  binding, justified by a one-line comment, matching how the rest of the file confines context state
  to `eventLoopQueue`.
- **`nonisolated(unsafe)` for the static re-entrancy key (error 1).** `queueKey` is a process-wide
  constant token used only to read/write a `DispatchSpecific` value on `eventLoopQueue`; it is set
  once and never mutated. Mark the `static let` `nonisolated(unsafe)` with a one-line justification.

### Non-Goals

- **No behavior change.** Operation dispatch, continuation resume, `Unmanaged` retain/release
  balance, timeout scheduling, and cancellation semantics are byte-for-byte unchanged. The
  `passRetained` still happens exactly once per call (the `async` block runs once); the matching
  `takeRetainedValue`/`release` sites are untouched.
- **No seam / bridge / Stream change.** The transport-seam connect path, `TransportBridge`,
  `TCPTransportApple`, and the `AsyncInputStream` EOF fix are untouched. Edits are confined to
  `AMSMB2/Context.swift`.
- **No new public API, no new type, no `Sendable` re-conformance.**

## Capabilities

### New Capabilities

- `swift6-strict-concurrency`: the testable contract that the package builds with **zero errors**
  under Swift 6.1 strict concurrency on **both** Linux and macOS, with no behavioral change to libsmb2
  operation dispatch (the full integration suite through the seam still passes with zero failures on
  macOS, and the Linux test suite builds and passes).

## Impact

- **`AMSMB2/Context.swift`** only:
  - `queueKey` static (`:107`) gains `nonisolated(unsafe)`.
  - `async_await(dataHandler:execute:)` (`~:849–934`): `cbPtr` constructed inside the `async` block;
    `handler` laundered via a `nonisolated(unsafe)` local.
  - `async_await_pdu(dataHandler:execute:)` (`~:944–`): same two edits.
- **Concurrency model**: unchanged. All laundered values remain confined to `eventLoopQueue`; no new
  shared-mutable state is introduced. Each `nonisolated(unsafe)` carries a one-line data-race-safety
  justification (see `design.md`).
- **Tests**: the fix is a compile-level change verified by the **dual-platform build**. The macOS
  no-regression bar is the existing unit suite plus the full Docker-Samba integration suite through
  the live seam (zero failures); the Linux bar is `make linuxtest` building **and** passing. No new
  test is required because no runtime behavior changes; the dual build is the acceptance evidence.
