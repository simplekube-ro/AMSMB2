## ADDED Requirements

### Requirement: Package builds with zero errors under Swift 6.1 strict concurrency on Linux and macOS

The package SHALL compile with **zero errors** under Swift 6.1 strict concurrency on **both** Linux
(`swift:6.1`) and macOS. None of the five `AMSMB2/Context.swift` strict-concurrency diagnostics —
the non-`Sendable` `queueKey` static, the `cbPtr` captures in `async_await(dataHandler:execute:)`
and `async_await_pdu(dataHandler:execute:)`, and the `handler` captures in those same runners —
SHALL remain. No `@Sendable` closure in the two legacy operation runners SHALL capture a
non-`Sendable` `UnsafeMutableRawPointer`.

#### Scenario: Linux build under Swift 6.1 succeeds

- **WHEN** the package is built on the `swift:6.1` Linux toolchain (`make linuxtest`)
- **THEN** the build completes with no `: error:` diagnostics
- **AND** the test suite builds and runs (no `fatalError`/compile abort)

#### Scenario: macOS build stays green

- **WHEN** the package is built and unit-tested on macOS (`swift build --disable-sandbox` /
  `swift test --disable-sandbox`)
- **THEN** the build succeeds and the unit suite passes
- **AND** no **new** strict-concurrency warning is introduced relative to `master` (the five prior
  `Context.swift` findings are gone; nothing new is added)

#### Scenario: The opaque callback pointer is constructed inside the serialized block

- **WHEN** `async_await(dataHandler:execute:)` or `async_await_pdu(dataHandler:execute:)` dispatches
  its `eventLoopQueue.async` block
- **THEN** the `Unmanaged.passRetained(cb).toOpaque()` opaque pointer is constructed as a block-local
  inside that block (not captured from the enclosing scope)
- **AND** only `Sendable` values (`cb`, `cbId`) cross the `@Sendable` boundary

#### Scenario: Each unsafe escape is confined and justified

- **WHEN** a `nonisolated(unsafe)` annotation is used to resolve a diagnostic — the `handler` local in
  each runner (both platforms) and the `queueKey` static (**Linux only**, via the
  `#if canImport(Darwin)` split: a plain `static let` on Apple, where `DispatchSpecificKey` is already
  `Sendable` and the annotation would be flagged "unnecessary")
- **THEN** the annotated value is confined to `eventLoopQueue` (the serial owner of `smb2_context`)
  or is an immutable process-wide constant
- **AND** each annotation carries a one-line comment justifying its data-race safety

### Requirement: No behavior change to libsmb2 operation dispatch

The fix SHALL NOT alter the runtime behavior of operation dispatch, `Unmanaged` retain/release
lifetime, timeout scheduling, or task cancellation. The `Unmanaged.passRetained(cb)` retain SHALL
occur exactly once per call, paired 1:1 with its existing release / `takeRetainedValue` sites (no
use-after-free, no double-free). The **library-source** fix SHALL be confined to
`AMSMB2/Context.swift`; the transport seam, bridge, `TCPTransportApple`, and
`AsyncInputStream`/`Stream.swift` SHALL be untouched. The change additionally includes the `Dockerfile`
image bump (`swift:6.0` → `swift:6.1`) and minimal, **test-only** Linux-portability fixes in
`AMSMB2Tests/` required to evaluate the Linux acceptance bar; these introduce no library behavior
change.

#### Scenario: Full integration suite through the seam stays green on macOS

- **WHEN** the full integration suite runs against live Docker Samba through the transport seam
  (`SMB_TRANSPORT=seam`) on macOS
- **THEN** every test passes (zero failures) — every libsmb2 operation is exercised through the two
  runners with the relocated `cbPtr` and laundered `handler`
- **AND** no test reports a use-after-free, double-free, or leak

#### Scenario: Callback retain/release remains balanced

- **WHEN** an operation completes normally, fails before registration (`context == nil` or `handler`
  throws), or is cancelled before its block runs
- **THEN** the `passRetained` on `cb` is balanced by exactly one release or `takeRetainedValue` on
  the corresponding path, identical to the pre-change topology

#### Scenario: Library-source fix confined to Context.swift

- **WHEN** the change is diffed against `master`
- **THEN** the only modified **library source** is `AMSMB2/Context.swift`
- **AND** the remaining modifications are limited to the `Dockerfile` image bump, **test-only**
  Linux-portability fixes in `AMSMB2Tests/`, and the OpenSpec artifacts
- **AND** no change appears in the seam, bridge, transport, or stream sources
