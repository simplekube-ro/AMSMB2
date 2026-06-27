---
name: Swift 6 strict-concurrency captures in Context.swift
description: swift:6.1 Linux hard-errors on @Sendable captures that macOS only warns on; sanctioned fix patterns
type: project
---

The `eventLoopQueue.async { @Sendable ... }` blocks in `SMB2Client` (Context.swift) are the
canonical site of strict-concurrency capture diagnostics. macOS surfaces them as warnings (build
green); `swift:6.1` on Linux promotes them to **hard errors**, so the Linux build is the real gate.

**Sanctioned fix patterns (established, in priority order):**
1. **Non-Sendable raw pointers (`cbPtr`/`UnsafeMutableRawPointer`):** do NOT capture across the
   `@Sendable` boundary. Construct `Unmanaged.passRetained(cb).toOpaque()` as a block-local INSIDE
   the `.async` block, immediately before its consumer. Reference impl: `connectWithBridge`
   (~Context.swift:1153–1161). Only the Sendable `cb` (`CBData` is `@unchecked Sendable`) and `cbId`
   (`ObjectIdentifier`) are captured. This keeps the bridge-retain topology intact because the
   `.async` block runs exactly once and `cb` is independently kept alive by the function scope +
   `pendingOperations` + closures.
2. **A non-Sendable closure that MUST cross (the operation `handler: UnsafeContextHandler`):** launder
   with a function-scope `nonisolated(unsafe) let confinedHandler = handler`, justified by the fact
   it is invoked exactly once on `eventLoopQueue` (the serial owner of `smb2_context`). Must be
   function-scope, not inside the block, or the capture isn't laundered. Do NOT make the typealias
   `@Sendable` — that ripples to every call site.
3. **Non-Sendable immutable statics (`queueKey: DispatchSpecificKey`):** `nonisolated(unsafe)` —
   immutable identity token, set once; per-queue value lives in DispatchQueue specific storage.

**Guardrail:** the two legacy generic runners `async_await(execute:)` / `async_await_pdu(execute:)`
drive EVERY libsmb2 op on both platforms — any retain/release mistake corrupts all I/O. The 4
release sites (context==nil guard, isAbandoned cancel-before-run guard, handler-throws catch,
success via `generic_handler.takeRetainedValue()`) must stay 1:1 with a single `passRetained`.
`onCancel` references only `cb`/`cbId`, never `cbPtr`.

Acceptance is dual-platform: macOS unit + full Docker-Samba seam integration suite (0 failures) AND
`make linuxtest` building+passing under swift:6.1. Grep logs for `: error:` / `failed (` — do not
trust tail-piped exit codes.
