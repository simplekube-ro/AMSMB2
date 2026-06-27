# fix-swift6-concurrency: swift:6.1 Linux promotes strict-concurrency warnings to hard errors

The Apple toolchain surfaces this module's strict-concurrency findings as **warnings** (build stays
green); `swift:6.1` on Linux treats the same findings as **errors** and aborts. A clean macOS build
does NOT prove Linux compiles. Verify Linux with `make linuxtest` (Docker swift:6.1). Don't trust
tail-piped exit codes — grep logs for `: error:` / `Fatal error` / `failed (`.

## Fix patterns for `@Sendable` `eventLoopQueue.async` blocks (Context.swift)
- **Non-Sendable raw pointer captured into the block** (`cbPtr = Unmanaged.passRetained(cb).toOpaque()`):
  do NOT capture — **construct it block-local** inside `eventLoopQueue.async { ... }`, immediately
  before its sole consumer. Reference impl: `connectWithBridge`. `cb` (CBData `@unchecked Sendable`)
  and `cbId` (ObjectIdentifier) may cross. Block runs exactly once → `passRetained` still once →
  retain/release topology unchanged (no use-after-free / double-free).
- **Non-Sendable closure that MUST cross** (`handler: @escaping UnsafeContextHandler<R>`): launder with
  `nonisolated(unsafe) let confinedHandler = handler` at **function scope** (NOT inside the block — that
  doesn't launder the capture), then call `confinedHandler(...)`. Justified: invoked once on
  `eventLoopQueue`, the serial owner of `smb2_context`.
- The two legacy runners `async_await(dataHandler:execute:)` / `async_await_pdu(dataHandler:execute:)`
  drive every libsmb2 op — never alter retain/release.

## `DispatchSpecificKey<Bool>` Sendable divergence (queueKey, Context.swift)
Apple: `DispatchSpecificKey` IS `Sendable` → plain `static let` correct; `nonisolated(unsafe)` triggers
a NEW `'nonisolated(unsafe)' is unnecessary` warning. Linux swift 6.1: NOT `Sendable` → needs
`nonisolated(unsafe)`. No single annotation works → `#if canImport(Darwin)` (plain `let`) `#else`
(`nonisolated(unsafe) let`).

## Linux test-target portability gotchas (swift-corelibs-foundation)
Only surface once the library compiles on Linux (else the test target never builds — they hide behind
the library errors):
- `URLCredential` is in **`FoundationNetworking`**, not `Foundation`: `#if !canImport(Darwin) import
  FoundationNetworking #endif` (matches `AMSMB2.swift`).
- `NSEC_PER_SEC` is `UInt64` on Darwin but **`Int`** on Glibc → `Task.sleep(nanoseconds:
  UInt64(NSEC_PER_SEC))`.
- `NSKeyedUnarchiver` secure-coding round-trip **fatally aborts** (`.raiseException`, SIGTRAP, kills the
  WHOLE suite) on swift-corelibs-foundation when a key is missing (e.g. intentionally-unserialized
  password) — even when the test sets `.setErrorAndReturn` (a nested decoder uses `.raiseException`).
  Guard such tests `#if canImport(Darwin)`; JSON `Codable` covers the same invariant cross-platform.
  `copy(with:)` that rebuilds directly (no archiving) is Linux-safe.

## Scope lesson
Fixing the 5 library concurrency errors let the Linux test target compile for the first time, exposing
4 pre-existing unrelated test-portability defects. "Confine to Context.swift" collided with the
"make linuxtest must pass" acceptance bar. Resolution: apply the minimal repo-idiomatic test fixes and
flag the scope expansion in tasks.md/design.md for architect re-gate — don't hide it.
