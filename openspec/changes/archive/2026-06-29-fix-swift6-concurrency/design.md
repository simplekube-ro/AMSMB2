## Context

`SMB2Client` (`AMSMB2/Context.swift`) owns a single `smb2_context` pointer and serializes **all**
access to it through `eventLoopQueue`, a dedicated serial `DispatchQueue` (`Context.swift:102–104`).
Every async libsmb2 operation funnels through one of two legacy generic runners:

- `async_await(dataHandler:execute:)` (`~:849–934`) — for ops driven by `smb2_command_cb`.
- `async_await_pdu(dataHandler:execute:)` (`~:944–`) — for ops that queue a raw `smb2_pdu`.

Both follow the same shape: build a `CBData` (`cb`), retain it into an opaque pointer (`cbPtr`) so it
survives until `generic_handler` calls `takeRetainedValue()`, then `eventLoopQueue.async { … }` a
`@Sendable` block that (on the queue, with exclusive `smb2_context` access) invokes the caller's
`handler`, registers the continuation, and arms the timeout. Today `cbPtr` and `handler` are computed
**before** the `async` block and captured into it. Under Swift 6.1 strict concurrency a `@Sendable`
closure may not capture non-`Sendable` values, so both captures are diagnosed.

The seam path already hit and solved the identical `cbPtr` problem in `connectWithBridge`
(`Context.swift:1148–1161`): it captures only the `Sendable` `cb`/`cbId` and constructs the
`UnsafeMutableRawPointer` *inside* the `async` block as a block-local. This change applies that same
pattern to the two legacy runners and clears the lone non-`Sendable` static.

### Why these are warnings on macOS but errors on Linux

The Apple toolchain in this repo surfaces the module's strict-concurrency findings as warnings (the
build stays green), whereas `swift:6.1` on Linux treats the same findings as hard errors and aborts
compilation. The defects are identical on both platforms; only the severity differs. Fixing them
makes the source clean under the stricter interpretation **without** changing the macOS result.

## Goals / Non-Goals

**Goals**
- The package compiles with **zero errors** under Swift 6.1 strict concurrency on Linux **and** macOS.
- Each of the five diagnostics is resolved with the **minimal, idiomatic** Swift 6 escape, matching
  the in-file reference (`connectWithBridge`) and the file's existing `eventLoopQueue`-confinement
  discipline.
- **No behavior change** to operation dispatch, `Unmanaged` lifetime, timeout, or cancellation.

**Non-Goals**
- No seam / bridge / `Stream.swift` change. No public API change. No new type or `Sendable`
  re-conformance. No refactor of the runners beyond the capture fixes.

## Decisions

### D-1 — `cbPtr` constructed locally inside the `async` block (errors 2 & 4)

In **both** runners, today:

```swift
let cb = CBData()
…
let cbPtr = Unmanaged.passRetained(cb).toOpaque()   // captured into @Sendable block ⇒ error
let cbId = ObjectIdentifier(cb)

try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
        self.eventLoopQueue.async {
            guard let context = self.context else {
                Unmanaged<CBData>.fromOpaque(cbPtr).release()   // uses captured cbPtr
                …
            }
            let result = try handler(context, cbPtr)            // uses captured cbPtr + handler
            …
        }
    }
} onCancel: {
    self.eventLoopQueue.async { … uses cb / cbId, NOT cbPtr … }
}
```

After (mirrors `connectWithBridge`):

```swift
let cb = CBData()
…
let cbId = ObjectIdentifier(cb)                       // cbPtr no longer computed here

try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
        self.eventLoopQueue.async {
            // Construct the opaque pointer locally to avoid capturing a non-Sendable
            // UnsafeMutableRawPointer across the @Sendable closure boundary (see connectWithBridge).
            let cbPtr = Unmanaged.passRetained(cb).toOpaque()
            guard let context = self.context else {
                Unmanaged<CBData>.fromOpaque(cbPtr).release()
                …
            }
            …
        }
    }
} onCancel: { … unchanged; never referenced cbPtr … }
```

**Why this is data-race-safe and behavior-preserving.**
- `cb` (`CBData`) is `@unchecked Sendable` and `cbId` (`ObjectIdentifier`) is `Sendable`, so both
  legitimately cross the `@Sendable` boundary; only the raw pointer was the offender.
- The `eventLoopQueue.async` block executes **exactly once**, so `Unmanaged.passRetained(cb)` runs
  exactly once — identical retain count to today. The opaque pointer's lifetime is unchanged: it is
  released on the `context == nil` / `handler`-throws / cancellation-before-run paths inside the
  block, or handed to libsmb2 and reclaimed by `generic_handler`'s `takeRetainedValue()` exactly as
  before. No use-after-free and no double-free is introduced — the retain and all its matching
  release/`takeRetainedValue` sites still pair 1:1.
- The `onCancel` block already operated on `cb`/`cbId` and never touched `cbPtr`, so moving `cbPtr`
  inward cannot affect cancellation. There is no path that needs `cbPtr` outside the `async` block.

### D-2 — `handler` laundered with a `nonisolated(unsafe)` local (errors 3 & 5)

`handler` is an `@escaping UnsafeContextHandler<R>` — a plain (non-`Sendable`) closure parameter that
**must** be invoked inside the `@Sendable` block (it is the operation body that touches the
`smb2_context`). Unlike `cbPtr`, it cannot be reconstructed locally; it has to cross the boundary.

The minimal idiomatic Swift 6 escape is a `nonisolated(unsafe)` binding that the block captures:

```swift
// `handler` is invoked only on eventLoopQueue (the serial owner of smb2_context); confined there,
// so crossing the @Sendable boundary is data-race-safe. nonisolated(unsafe) launders the capture.
nonisolated(unsafe) let confinedHandler = handler
```

and the block calls `confinedHandler(context, cbPtr)`.

**Why `nonisolated(unsafe)` is justified here (data-race-safety argument).**
- `handler` is captured by **exactly one** `eventLoopQueue.async` block and is invoked **exactly
  once**, on that serial queue. It is never stored, never copied to another queue/thread, and never
  invoked concurrently. Its effective isolation domain is `eventLoopQueue` — the same domain that
  exclusively owns the `smb2_context` the handler operates on.
- This is the file's established confinement convention: the whole point of `eventLoopQueue` is that
  everything touching the context runs single-threaded on it. `nonisolated(unsafe)` simply tells the
  compiler what the queue already guarantees at runtime; it asserts confinement rather than
  introducing shared mutable state.
- It is strictly narrower than alternatives (see below) and changes no behavior: the same closure is
  invoked at the same point with the same arguments.

### D-3 — `queueKey` static marked `nonisolated(unsafe)` (error 1)

```swift
/// Used to detect re-entrant calls to the event loop queue and avoid deadlocks.
// nonisolated(unsafe): a process-wide constant token, set once and never mutated. It is only used to
// read/write a DispatchSpecific value scoped to eventLoopQueue; the key itself carries no state.
private static nonisolated(unsafe) let queueKey = DispatchSpecificKey<Bool>()
```

**Why this is data-race-safe.** `DispatchSpecificKey` is a constant identity token: it is assigned
once at static-initialization time and never reassigned or mutated. The actual per-queue boolean it
keys into lives in the `DispatchQueue`'s specific storage, not in the key. Reading an immutable
token concurrently is inherently race-free; `nonisolated(unsafe)` records that the type merely lacks
a `Sendable` conformance it could safely have. (An alternative — wrapping it so it conforms to
`Sendable` — would add a type for no behavioral gain; `nonisolated(unsafe)` is the minimal escape and
matches the file's confinement style.)

## Alternatives considered

- **Make `cbPtr`/`handler` `Sendable` via wrapper structs.** Rejected: adds new types and ceremony
  for values that are already correctly confined to `eventLoopQueue`; the local-construction +
  `nonisolated(unsafe)` pattern is already established in this file (`connectWithBridge`) and is
  strictly smaller.
- **Mark the whole `eventLoopQueue.async` closure `@unchecked Sendable` / drop `@Sendable`.**
  Rejected: not possible for `DispatchQueue.async` (the parameter is `@Sendable () -> Void`), and it
  would suppress *all* capture checking in the block, weakening the very guarantee we want to keep
  precise.
- **`nonisolated(unsafe)` on `cbPtr` too** (instead of local construction). Rejected: local
  construction is the cleaner, already-proven fix for the pointer and needs no `unsafe` annotation;
  reserve `nonisolated(unsafe)` for `handler`, which genuinely must cross the boundary.
- **Refactor the two runners into one.** Rejected: out of scope; a behavior-neutral concurrency fix
  must not restructure the operation dispatch that drives every libsmb2 call.

## Risks

- **Pointer-lifetime regression (use-after-free / double-free).** The runners drive every libsmb2
  op, so a mistake here corrupts all I/O. Mitigation: the retain/release topology is provably
  unchanged — `passRetained` still runs exactly once (the block runs once), and every existing
  release / `takeRetainedValue` site is byte-for-byte preserved; only the *line* where `cbPtr` is
  computed moves into the same block that already consumed it. Verified by the full live integration
  suite through the seam (every op exercised) staying at zero failures on macOS, and the Linux suite
  passing.
- **macOS regression.** The macOS build is currently green; the change must keep it green and must
  not alter dispatch. Mitigation: the dual-platform acceptance bar requires the macOS unit suite
  **and** the full Docker-Samba seam integration suite (148 tests) to remain at zero failures.
- **Over-broad `nonisolated(unsafe)`.** Mitigation: applied to exactly two surfaces (`handler` local,
  `queueKey` static), each with a one-line justification tying it to `eventLoopQueue` confinement /
  immutability; `cbPtr` deliberately uses local construction instead, so no `unsafe` is spent on it.

## Architect Review Gate

**Verdict: GATE_APPROVED — approach as-proposed (`project-architect`, 2026-06-27).**

> **RE-GATE RESOLUTION — `project-architect`, 2026-06-30 (guardrail 4 scope expansions).**
> Following the `swift-code-reviewer` pass (task 4.1, APPROVED — no blocking findings), the two scope
> expansions surfaced during implementation were re-gated:
> - **C2b test-portability fixes (deviation #2): ACCEPT into this change (ruling A).** Acceptance bar
>   (B) — "`make linuxtest` builds *and* passes" — is part of the gated scope and is unprovable without
>   a compiling Linux test target. These defects could only surface *after* the five library errors
>   cleared, so they are causally downstream of this change; splitting them would create a verification
>   deadlock. Test-only, no library behavior change.
> - **Agent/Codex scaffolding in `d2c0d18` (deviation #3): out-of-scope, record-only (ruling B).** Not
>   part of the capability and absent from `spec.md`, so archive does not bless it into `openspec/specs/`.
>   Already merged + user-retained; no revert/rewrite required — disowned in the artifacts instead.
> - **Pre-existing `async_await_pdu` indentation:** correctly left untouched; track as a separate
>   SwiftFormat `chore:`.
>
> **Re-gate verdict: APPROVED — CONDITIONAL.** Archive cleared once the artifacts tell the truth about
> what shipped: (1) `spec.md` confinement scenario corrected to "library-source fix confined to
> `Context.swift`" (done), (2) `design.md` deviation #3 added for the scaffolding (done), (3) this
> resolution stamped (done). The engineering is not reopened.

The four verification points were checked against the live source (`Context.swift`,
`async_await` 849–934, `async_await_pdu` 944–1023, `connectWithBridge` 1153–1161, `queueKey` 107):

- **(a) Retain/release balance is genuinely unchanged by the `cbPtr` move.** `cbPtr` is the *bridge*
  retain handed to the C side; `cb` itself is independently kept alive by the enclosing function
  scope (`let cb = CBData()`), by `pendingOperations[cbId]`, and by the continuation/timeout/cleanup
  closures — so moving `passRetained` later does not risk premature deallocation. The
  `eventLoopQueue.async` block runs **exactly once**, so `passRetained` still runs exactly once. The
  four mutually-exclusive release sites (`context == nil` guard, cancel-before-run `isAbandoned`
  guard, `handler`-throws `catch`, and success reclaimed by `generic_handler.takeRetainedValue()`)
  are all **inside** the block and are byte-for-byte preserved. No code path outside the block
  references `cbPtr`: confirmed the trailing code (`async_await` 929–933, `async_await_pdu` 1019–1022)
  reads only `cb.error`/`cb.result`/`cb.status`/`dataHandlerError`, and `onCancel` reads only
  `cb`/`cbId`. **No use-after-free, no double-free, no leak** — constructing `cbPtr` immediately
  before its sole consumer (`handler(context, cbPtr)`) is strictly tighter and matches
  `connectWithBridge`.

  - *Ordering subtlety checked:* if cancellation fires after the (old eager) `passRetained` but before
    the block runs, `onCancel` sets `isAbandoned` and does **not** resume (continuation is still nil);
    the block then takes the `isAbandoned` guard, releases `cbPtr`, and resumes `CancellationError()`.
    With local construction the retain/release pair both move into that same block — identical net
    effect. The move actually *narrows* the window in which a bridge retain is outstanding.

- **(b) `handler` is provably invoked only on `eventLoopQueue`.** Each runner calls `handler` at a
  **single** site inside the `.async` block (`async_await` 879, `async_await_pdu` 972); it is never
  stored, copied to another queue, or invoked concurrently. Its effective isolation domain is the
  serial queue that exclusively owns `smb2_context`. `nonisolated(unsafe)` here *asserts* the
  confinement the queue already enforces; it introduces no shared-mutable state. Approved.

- **(c) `queueKey` is never mutated after initialization.** It is a `private static let`
  `DispatchSpecificKey` — an immutable identity token assigned once at static init; the per-queue
  boolean lives in `DispatchQueue` specific storage, not the key. `setSpecific`/`getSpecific` are
  themselves thread-safe. `nonisolated(unsafe)` records the missing-but-safe `Sendable`. Approved.

- **(d) Confinement.** The change is confined to `Context.swift`; it does not touch the seam, bridge,
  `TCPTransportApple`, or `Stream.swift`. Confirmed against the Non-Goals and the `git diff --stat`
  gate in task 2.5.

### Conditions / guardrails (binding on the implementer)

1. **`handler` launder placement.** Declare `nonisolated(unsafe) let confinedHandler = handler` at
   **function scope** (before `withTaskCancellationHandler`) so the binding the `.async` block
   captures is the laundered one. Declaring it *inside* the block does not launder the capture of
   `handler` and leaves the diagnostic. Replace the **single** `handler(...)` call site in each runner
   with `confinedHandler(...)`; verify `handler` is referenced **nowhere else** in the block (it is
   not, today). Do not make the `UnsafeContextHandler` typealias `@Sendable` — that is a broader
   API-surface change rippling to every call site and is out of scope.
2. **No `nonisolated(unsafe)` on `cbPtr`.** Use local construction (D-1), not an `unsafe`
   annotation — reserve `nonisolated(unsafe)` for the two surfaces that genuinely must cross
   (`handler` local, `queueKey` static).
3. **Retain/release audit is mandatory (task 2.4).** After the edit, re-read both runners end-to-end
   and confirm exactly one `passRetained` per block execution and a 1:1 release on every
   non-success exit, success reclaimed by `generic_handler`.
4. **Honesty.** If the live build surfaces any diagnostic beyond these five (e.g. a `continuation`
   or `self` capture the compiler now flags once the louder ones are cleared), do **not** silently
   broaden the fix — update this design with the new finding and re-enter the gate.

### Second/third-order implications (traced, clear)

- *Second-order:* the runners drive **every** libsmb2 op on both platforms; a retain mistake corrupts
  all I/O. Traced above — topology unchanged. The platform-agnostic runners carry no `#if`, so the
  fix lands identically on the Linux legacy `SocketMonitor` path and the Apple seam path.
- *Third-order:* `generic_handler.takeRetainedValue()` reclaims the *same* opaque pointer passed into
  `handler(context, cbPtr)`; since that pointer is built immediately before the unchanged call, the
  C-side reclamation is unaffected. `NSSecureCoding`/`Codable` and public API are untouched (no type
  or signature change), so persistence and consumer contracts are unaffected.

## Implementation deviations (recorded honestly; flagged for re-gate)

Three deviations from the approved plan are recorded:

1. **D-3 / `queueKey` — `#if canImport(Darwin)` split (not a bare `nonisolated(unsafe)`).** The Apple
   toolchain treats `DispatchSpecificKey<Bool>` as `Sendable`, so a `nonisolated(unsafe) static let`
   triggers a *new* macOS warning `'nonisolated(unsafe)' is unnecessary`. To keep **both** platforms
   clean, Apple uses a plain `static let` and Linux uses `nonisolated(unsafe)`. D-1/D-2 (the runner
   fixes) landed exactly as approved.

2. **Out-of-`Context.swift` test-portability fixes (C2b in `tasks.md`).** Clearing the five library
   errors let the test target compile on Linux **for the first time**, exposing pre-existing,
   unrelated `master` defects: (a) `FoundationNetworking` import for `URLCredential`; (b) `NSEC_PER_SEC`
   `Int`/`UInt64`; (c) two swift-corelibs-foundation `NSKeyedUnarchiver` fatal-abort tests guarded
   Apple-only; and (d) `, @unchecked Sendable` on three integration test classes
   (`SMB2DisconnectTimeoutTests`, `SMB2IntegrationTests`, `SMB2ManagerTests`) — `XCTestCase` is not
   `Sendable` on swift-corelibs-foundation, so 6.1 strict concurrency rejects the `self`-capturing
   async test bodies on Linux. None are concurrency regressions or in `Context.swift`, but acceptance
   bar (B) — "`make linuxtest` builds **and** passes" — cannot be met without them. Each fix is
   minimal, test-only, and mirrors an existing in-repo convention; no library behavior changed.

3. **Unrelated agent/Codex scaffolding bundled in `d2c0d18`.** ~2200 lines of `.agents/`, `.codex/`,
   `AGENTS.md`, and `.gitignore` tooling were committed alongside the swift6 fix (per request). This is
   out-of-scope tooling — it resolves no diagnostic, touches no library source, and advances neither
   acceptance bar. It is **not** represented in `spec.md`, so archiving this change does not bless it
   into `openspec/specs/`. Retained as tracked tooling per user decision; flagged here for honesty, not
   reverted (the commit is already merged — a split would be a retroactive history rewrite, which is
   off the table for a no-behavior-change tooling bundle).

**Verified result:** macOS `swift build`/unit clean + full live seam suite 148 tests / 0 failures;
Linux `make linuxtest` exit 0, 114 tests / 0 failures. Re-confirmed at re-gate (2026-06-30): macOS
build exit 0 with zero concurrency/Sendable warnings, unit suite 158 tests / 51 skipped / 0 failures.
