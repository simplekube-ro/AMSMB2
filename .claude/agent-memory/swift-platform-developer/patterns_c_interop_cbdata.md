---
name: CBData Unmanaged retain pattern for libsmb2 callbacks
description: How to safely hand CBData to libsmb2 so it stays alive until the callback fires, even after a caller timeout
type: project
---

When handing a Swift object to a C callback via `UnsafeMutableRawPointer`, always use
`Unmanaged.passRetained` at the call site and `takeRetainedValue` in the callback.
Never use `passUnretained`/`takeUnretainedValue` for objects that outlive the enqueue point.

**Why:** If the caller times out and returns before the C callback fires, the CBData object
would be deallocated. The subsequent callback invocation would then dereference freed memory
(use-after-free). `passRetained` increments the ref-count so the object stays alive until
`takeRetainedValue` decrements it inside the callback.

**Balancing releases on error paths — ONLY before the PDU is queued:** If the C call fails so
that *no PDU was registered* (context nil; `smb2_*_async`/`smb2_queue_pdu`/`smb2_connect_share_async`
threw or returned `< 0`; `smb2_set_transport` failed), the callback will never fire, so manually
call `Unmanaged<CBData>.fromOpaque(cbPtr).release()` to balance the `passRetained`.

**NEVER release after the PDU is queued (UAF trap — fix-cbdata-cancel-race-uaf):** Once the async
call succeeded and the PDU is queued, libsmb2 owns `cbPtr` and fires `generic_handler` *exactly
once* — on the reply, or during `smb2_destroy_context`'s teardown sweep (init.c walks the queues
and fires every pending PDU's cb with `SMB2_STATUS_SHUTDOWN`). The single balancing
`takeRetainedValue()` lives there. A cancellation/timeout observed in the post-queue window (the
`guard !cb.isAbandoned else { ... }` branches in `async_await`/`async_await_pdu`, and the
`if cb.isAbandoned` branch in `connectWithBridge`) MUST abandon — set `isAbandoned`, resume the
continuation with `CancellationError`, `return` — WITHOUT releasing. Releasing there double-balances
→ heap-use-after-free when the late callback runs (ASan: `heap-use-after-free at Context.swift` in
`generic_handler`). The seam connect's `cbPtr` is reached at destroy via libsmb2's internal connect
callback chain (`connect_data->cb` → `c_data->cb` = our `generic_handler`), so it is still balanced
exactly once at `deinit`. Mirror the already-correct `onCancel`/timeout paths, which abandon without
releasing. Fence the two surviving `catch` releases with a comment: they are reachable only
pre-queue; never add a throwing call after the async/queue call succeeds.

**isAbandoned flag:** Add `var isAbandoned = false` to CBData. On timeout or connection failure,
set `isAbandoned = true` on the event loop queue before removing from `pendingOperations`.
In the callback, check `isAbandoned` and return without signaling the semaphore if true.
This prevents a double-signal (which would corrupt the semaphore count) when timeout races
with the callback.

**failAllPendingOperations:** Must set `isAbandoned = true` on each cb *before* signaling its
semaphore, and must run on the event loop queue.

**Pattern in this codebase:**
```swift
// At call site (on event loop queue):
let cbPtr = Unmanaged.passRetained(cb).toOpaque()
// ... pass cbPtr to libsmb2 async function ...
// On error (callback will never fire):
Unmanaged<CBData>.fromOpaque(cbPtr).release()

// In generic_handler (C callback):
let cbdata = Unmanaged<CBData>.fromOpaque(try cbdata.unwrap()).takeRetainedValue()
if cbdata.isAbandoned { return }
// ... signal semaphore ...
```

**How to apply:** Any time a Swift object pointer is passed to a C async API where the
callback may arrive after the Swift call site has already thrown or returned.
