# swift-platform-developer — AMSMB2 notes

## Build / verification
- Always `--disable-sandbox`: `swift build --disable-sandbox`, `swift test --disable-sandbox [--filter X]`.
- `swift build --build-tests --disable-sandbox` is the cheapest way to prove a TDD "red" (compile failure).
- `make linuxtest` (Docker) works and rebuilds the whole package on Linux; grep its output for
  `Compiling AMSMB2 <File>.swift` to *prove* a new file compiled under the `#else` (non-Network) branch.
- `swiftformat` and `swift-format` are NOT installed on this machine (as of 2026-08); lint steps must be
  reported as "tool unavailable", never faked. Manual check: `awk 'length > 120'` (style limit 100/132).
- `timeout(1)` does not exist in this zsh env (use the Bash tool's own `timeout` param).

## Test-double seams (QUIC)
- `AMSMB2Tests/QUICTransportAppleTests.swift` defines internal doubles reusable from any test file in
  the target: `TestFlag`, `ScriptedQUICDriver`, `ManualDeadlineScheduler`, `ImmediateFireScheduler`,
  `GatedStartDriver`. `waitUntil(_:_:)` is private per-file — copy the 10-line poller, don't widen it.
- Pattern for "cancel before the attempt is committed": `withUnsafeCurrentTask { $0?.cancel() }` inside
  the injected `driverFactory` closure (it runs on the connect task, between `Task.checkCancellation()`
  and the continuation store).
- `XCTAssertEqual(try await x, y)` does NOT compile (autoclosure isn't async) — hoist to a `let` first.

## QUIC transport / probe architecture
- `QUICResolvedTrust` cases: `.system` (no verify block) / `.customRoots` / `.insecure` / `.capture(slot)`.
  `.capture` is internal-only, installed solely by `SMBQUICCertificateProbe` through the internal
  `QUICTransportApple.init(configuration:connectTimeout:driverFactory:deadline:)`, whose factory
  *discards* the `trust` argument the transport passes.
- `SMB2Client.validateQUICEndpoint(host:port:)` / `validatedQUICEndpoint(_:)` (Context.swift, inside the
  `#if canImport(Network)` region) are the single home of the numeric-host + 1...65535 rules.
  `connect`'s `.quic` branch must keep calling `parseSeamEndpoint` exactly once — it validates the
  already-parsed pair, it does NOT call `validatedQUICEndpoint`.
- `QUICTransportApple.close()` is cancellation-safe (awaits only non-throwing teardown continuations),
  so "always `await close()` even on CancellationError" is safe. Read shared capture state only AFTER
  close returns — that is when the started driver is guaranteed cancelled and its handlers cleared.
- Linux `ENOTSUP` spelling (`.ENOTSUP` is not a `POSIXErrorCode` case there):
  `throw POSIXError(.init(ENOTSUP), description: ...)` with `#if canImport(Glibc) import Glibc #endif`.
