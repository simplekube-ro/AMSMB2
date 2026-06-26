# Actor-Based Cancellable Receive Pattern

Used in `MockTransport` (AMSMB2Tests/MockTransport.swift) and should be used in
any actor that needs a "wait for next item" async method that supports Task cancellation.

## Pattern

```swift
actor MyQueue {
    private var buffer: [Item] = []
    private var waitingContinuation: CheckedContinuation<Item, any Error>?

    func enqueue(_ item: Item) {
        if let continuation = waitingContinuation {
            waitingContinuation = nil
            continuation.resume(returning: item)
        } else {
            buffer.append(item)
        }
    }

    func dequeue() async throws -> Item {
        if let item = buffer.first {
            buffer.removeFirst()
            return item
        }
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    // CRITICAL: check isCancelled here, after the handler is
                    // registered. Closes the race where onCancel fires before
                    // waitingContinuation is set (onCancel is a noop in that
                    // case, so we'd store a continuation that never gets resumed).
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        self.waitingContinuation = continuation
                    }
                }
            },
            onCancel: { [self] in
                // onCancel runs off the actor's executor; hop back via Task.
                Task { await self.cancelWaiting() }
            }
        )
    }

    private func cancelWaiting() {
        guard let continuation = waitingContinuation else { return }
        waitingContinuation = nil
        continuation.resume(throwing: CancellationError())
    }
}
```

## Why the `Task.isCancelled` check is required

Timeline of the race condition this protects against:
1. Task is already cancelled before `withTaskCancellationHandler` is called.
2. `withTaskCancellationHandler` calls `onCancel` immediately (synchronously).
3. `onCancel` creates `Task { await self.cancelWaiting() }` — but `waitingContinuation`
   is still `nil` at this point, so the task does nothing when it runs.
4. The operation body runs, skips the `if Task.isCancelled` check (not there!), and
   stores the continuation → it is NEVER resumed → leaked continuation → hang.

With the check: step 4 detects `isCancelled`, resumes immediately with `CancellationError`.

## Key rules

- Only one `waitingContinuation` at a time; never store two.
- `enqueue` / `signalEOF` / `close` must all check and clear `waitingContinuation`.
- `onCancel` must hop to the actor via `Task { await self.method() }` — never call
  actor methods synchronously from `onCancel` (it runs on an unspecified executor).
- Capturing actor `self` in `@Sendable` closures is valid: actor conforms to `Sendable`.
