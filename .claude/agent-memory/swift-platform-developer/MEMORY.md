# Agent Memory Index

- [feedback_response_style.md](feedback_response_style.md) — No emojis; no trailing summaries; share absolute file paths only
- [project_change_notify_bug.md](project_change_notify_bug.md) — monitorItem/Change Notify crashes due to async callback lifetime bug in Swift wrapper; test skipped with fix notes
- [patterns_c_interop_cbdata.md](patterns_c_interop_cbdata.md) — CBData lifetime / Unmanaged retain patterns for libsmb2 callbacks
- [patterns_dispatch_queue_reentry.md](patterns_dispatch_queue_reentry.md) — Detecting re-entrant eventLoopQueue calls with DispatchSpecificKey
- [libsmb2_fork_api_changes.md](libsmb2_fork_api_changes.md) — Fork submodule SHA, dreamcast exclude, C struct renames, new transport API symbols
- [patterns_c_char_pointer_import.md](patterns_c_char_pointer_import.md) — `char *` → non-optional UnsafeMutablePointer (no .map); `const char *` → optional UnsafePointer (has .map). Use bitPattern bridge for null-safe access on mutable fields.
