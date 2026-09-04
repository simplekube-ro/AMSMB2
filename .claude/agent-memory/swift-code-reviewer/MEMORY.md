# AMSMB2 — swift-code-reviewer memory

## Build / test facts (verified)
- `swift build --disable-sandbox` and `swift test --disable-sandbox --filter <regex>` work; plain
  `make test` fails in the sandbox.
- SwiftPM is incremental: after `swift build` reports `[Using on-disk description]` no warnings are
  re-emitted. **`touch` the changed files and rebuild** before claiming "zero new warnings".
- Known **pre-existing** warnings on master (do NOT attribute to a change): `ImplicitStrongCapture`
  ("'weak' ownership of capture 'self'/'cb' differs from implicitly-captured strong reference") in
  `AMSMB2/Context.swift` around lines 1041, 1049, 1158, 1165, 1718, 1741 (from commit e3670e6).
- Line-width rule that is actually enforced: `.swiftformat --maxwidth 132`. `.swift-format`
  `lineLength: 100` is advisory — existing code routinely exceeds 100. Only flag > 132.
- Package.swift is `swift-tools-version:6.0` → Swift 6 language mode, strict concurrency.

## Confirmed project conventions
- Errors are `POSIXError` only. `POSIXError(_:description:)` and `POSIXErrorCode.init(_ code: Int32)`
  (total, falls back to `.ECANCELED`) live in `AMSMB2/Extensions.swift:~70-80`. The Linux
  "no QUIC" spelling is `throw POSIXError(.init(ENOTSUP), description: ...)` — precedent
  `AMSMB2/AMSMB2.swift:1616`.
- Every `.swift` file carries the MIT header block; 4-space indent, no tabs.
- Test doubles live in `AMSMB2Tests/QUICTransportAppleTests.swift` at file scope and are reused
  across QUIC test files: `TestFlag`, `ScriptedQUICDriver`, `ManualDeadlineScheduler`.
  Check there before accepting a newly-written double as necessary.
- Integration/interop suites gate on env vars in `setUpWithError()` with `throw XCTSkip(...)`.

## Architecture notes worth reusing
- `AMSMB2/QUICTransportApple.swift` is the QUIC transport. Its connect state machine (design D7)
  is a proven claim/handoff/deadline/cancel/close set — reviews should verify callers *reuse* it
  rather than re-deriving it. Key guarantees relied on by callers:
  - `close()` is cancellation-safe (only non-throwing continuations) → always `await`-able, even
    from an already-cancelled task.
  - `close()` returns only after teardown + in-flight connect work drained → a *started* driver was
    cancelled exactly once.
  - `.ready` deliberately RETAINS the driver; every loss path nils it. So "cancelled exactly once"
    holds across both.
  - Internal init injects `driverFactory` + `ConnectDeadlineScheduler` — the seam every
    deterministic test (and now `SMBQUICCertificateProbe`) uses.
- `sec_trust_copy_ref(trustRef).takeRetainedValue()` is the established (correct, +1) idiom in every
  verify block. `SecTrustCopyCertificateChain` is `_Nullable CF_RETURNS_RETAINED` → imports as a
  managed `CFArray?`, no `Unmanaged` handling needed.
- Verify blocks must call `complete(...)` exactly once on **every** path — a trap or early return
  hangs the handshake until the connect deadline. Check totality of every helper called inside.
- QUIC endpoint policy (numeric-host + 1...65535) is factored into
  `SMB2Client.validateQUICEndpoint(host:port:)` / `validatedQUICEndpoint(_:)` in `Context.swift`.
  `connect`'s `.quic` branch must keep calling `parseSeamEndpoint` exactly once.

## Recurring findings to check for in this repo
1. **Unused imports** in new files guarded by `#if canImport(Network)` — module-internal types
   (`NWConnectionQUICDriver`, `QUICTransportApple`, …) need no `import Network`/`import Security`.
2. **Invariant enforced in a different file from where it is relied on** (e.g. "the slot never holds
   an empty array" guarded at the writer, assumed at the reader). Push the guard to the type.
3. **Design-doc outcome tables drifting from the implemented precedence order.** CLAUDE.md requires
   artifacts to match implementation — reread the table row by row against the code.
4. **Values passed for "truthfulness" that no code reads** (e.g. a `connectTimeout` in a config the
   internal init ignores) — flag when the dead value can disagree with the live one.
5. Tests that call `withUnsafeCurrentTask { $0?.cancel() }` from an async XCTest method cancel the
   *test's own* task; prefer wrapping in `Task { }`.

## QUIC certificate probe (add-quic-certificate-probe) — verified facts
- `AMSMB2/SMBQUICCertificateProbe.swift`: public `SMBQUICCertificateProbe.fetchServerCertificateChain`
  + internal `(server:timeout:driverFactory:deadline:)` seam. Outcome precedence (design D1):
  `CancellationError` → captured chain → transport error → `EPROTO`. `await transport.close()` runs
  on EVERY path *before* the slot is read — that ordering is the load-bearing invariant (test
  `testSlotIsReadAfterCloseReturned`).
- `QUICCertificateCaptureSlot.store` guards `!chain.isEmpty` — the "a stored chain is always
  non-empty" invariant lives in the type, not at the call site.
- `QUICResolvedTrust.capture(slot)` is internal-only, unreachable from `SMBQUICConfiguration.TrustPolicy`
  (`resolveTrust` cannot produce it) — the probe installs it via the driver-factory seam.
- `ScriptedQUICDriver` (AMSMB2Tests/QUICTransportAppleTests.swift) has an optional `onCancel` hook
  read under the lock and invoked OUTSIDE it. Default-nil, so other suites are unaffected.
- Pre-existing >132-col line: `AMSMB2/Context.swift:727` (commit 75e4db5c) — not a new-change finding.

## `xctrace` export format — verified empirically (2026-09-04, xctrace 16.0 (17F113))
Reproduced locally with a throwaway Swift emitter + `xcrun xctrace record --template 'Time Profiler'
--instrument os_signpost --launch`, then `xctrace export --xpath`:
- **A single `--xpath 'table[@schema="X"]'` export returns SEVERAL `<node>` elements. Only the FIRST
  carries `<schema>`; the row-bearing node(s) have NO `<schema>` child.** Any parser that does
  `if node.find("schema") is None: continue` silently drops every row. Seen every time for
  `os-signpost` (3 nodes: schema-only, empty, 79 rows); `time-profile` happened to be one node.
- **Values *inside* `<os-log-metadata>` are interned too**: a repeated argument arrives as
  `<uint64 ref="16"/>` with no text. A parser that resolves `ref` only on the row's top-level
  cells dies on it. Resolve nested children as well.
- `os_signpost` `%d` with a Swift `Int` **truncates to 32 bits** (`0x1_0000_0002` → `2`); `%ld` is
  exact. Either way xctrace renders the arg as `<uint64>`, and `-1` arrives as
  `18446744073709551615` (sign-extended), so a uint64→signed fold is the right decode.
- Format `"%d"` → `<format-string>%d</format-string>` and `<os-log-metadata><uint64/></os-log-metadata>`
  with **no** `<narrative-text>`. A prefixed format (`"terminal=%d"`) adds
  `<narrative-text>terminal=</narrative-text>` before the `<uint64>`. `emit-location` is a real
  `<return-location>` tree, not `<sentinel/>`.
- `event-type` texts are exactly `Event` / `Begin` / `End`; `.exclusive` IDs export as
  `17216892719917625070` (`fmt="OS_SIGNPOST_ID_EXCLUSIVE"`).
- `xctrace export --toc | grep` works fine (no `--output` needed) despite the "always pass --output"
  advice, which applies to `--xpath` exports into a closing pipe.
