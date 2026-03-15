---
name: Detecting re-entrant DispatchQueue calls with DispatchSpecificKey
description: Pattern to avoid deadlock when deinit or a property getter may already be on the serial event loop queue
type: project
---

When a serial `DispatchQueue` is used to serialize access to mutable state, calls to
`queue.sync { }` from code that is already running on that queue will deadlock.
Two common trigger points:

1. **deinit** — may be called from within a completion handler on the event loop queue.
2. **Property getters** — may be called from within the event loop queue (e.g., from a
   callback that reads `self.error` to format an error message).

**Fix:** Tag the queue with a `DispatchSpecificKey` and check it before any `queue.sync` call.

```swift
private static let queueKey = DispatchSpecificKey<Bool>()

// In init:
eventLoopQueue.setSpecific(key: Self.queueKey, value: true)

// Helper:
private func syncOnEventLoop<T>(_ work: () -> T) -> T {
    if DispatchQueue.getSpecific(key: Self.queueKey) == true {
        return work()  // Already on queue — call directly
    } else {
        return eventLoopQueue.sync { work() }
    }
}

// In deinit:
if DispatchQueue.getSpecific(key: Self.queueKey) == true {
    shutdown()
} else {
    eventLoopQueue.sync { self.shutdown() }
}
```

**How to apply:** Any time a `DispatchQueue.sync` is used to protect state that might also
be accessed from callbacks fired on that same queue.
