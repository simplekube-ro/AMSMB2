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

**Balancing releases on error paths:** If the C call fails (so the callback will never fire),
manually call `Unmanaged<CBData>.fromOpaque(cbPtr).release()` to balance the `passRetained`.

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
