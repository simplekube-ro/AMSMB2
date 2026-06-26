# Agent Memory Index

- [feedback_response_style.md](feedback_response_style.md) — No emojis; no trailing summaries; share absolute file paths only
- [project_change_notify_bug.md](project_change_notify_bug.md) — monitorItem/Change Notify crashes due to async callback lifetime bug in Swift wrapper; test skipped with fix notes
- [patterns_c_interop_cbdata.md](patterns_c_interop_cbdata.md) — CBData lifetime / Unmanaged retain patterns for libsmb2 callbacks
- [patterns_dispatch_queue_reentry.md](patterns_dispatch_queue_reentry.md) — Detecting re-entrant eventLoopQueue calls with DispatchSpecificKey
- [libsmb2_fork_api_changes.md](libsmb2_fork_api_changes.md) — Fork submodule SHA, dreamcast exclude, C struct renames, new transport API symbols
- [patterns_c_char_pointer_import.md](patterns_c_char_pointer_import.md) — `char *` → non-optional UnsafeMutablePointer (no .map); `const char *` → optional UnsafePointer (has .map). Use bitPattern bridge for null-safe access on mutable fields.
- [patterns_swift6_c_function_refs.md](patterns_swift6_c_function_refs.md) — C function aliases as global `let` fail Swift 6 concurrency; fix: move inside test methods as local `let functionRef: @Sendable (...) -> T = cFunction`.
- [patterns_nio_package_deps.md](patterns_nio_package_deps.md) — SwiftNIO + NIOTransportServices Apple-only Package.swift pattern (`.when(platforms:)` guard), resolved versions, D1 naming trap (never use SMB2_TRANSPORT_TCP for seam).
- XCTestCase subclasses: never add `@unchecked Sendable` unless the subclass actually crosses isolation boundaries — the conformance is inherited implicitly and the annotation adds noise. Drop `throws` from test functions that only use `try?` in defer blocks (the function itself never throws).
- [patterns_actor_cancellable_receive.md](patterns_actor_cancellable_receive.md) — Actor-based suspend-until-data pattern using withTaskCancellationHandler + withCheckedThrowingContinuation; race-safe via Task.isCancelled check inside continuation body.
- [patterns_transport_seam.md](patterns_transport_seam.md) — T4 transport seam: SMBTransport protocol + SMBTransportKind enum (AMSMB2/SMBTransport.swift); MockTransport actor double in test target; branch stack for TCP transport milestone.
- [patterns_transport_bridge.md](patterns_transport_bridge.md) — T5 TransportBridge: NSLock-in-async gotcha (use sync helpers), MockTransport loopback contention (separate pump startup for tests), Unmanaged lifetime discipline, `#if canImport(Network)` guard, lock ALL mutable state including Task refs, double-start guard pattern, ByteFIFO inlined (not separate type).
