## Capability: task-cancellation

Per-operation Swift Task cancellation via `withTaskCancellationHandler`, integrated with event loop continuation tracking.

## Requirements

### R1: Every async SMB2Manager method must support Task cancellation
- Each async method wraps its continuation with `withTaskCancellationHandler`
- On cancellation, the handler removes the continuation from the event loop's tracking and resumes with `CancellationError`

### R2: Fast-path cancellation check before submission
- Each async method calls `try Task.checkCancellation()` before submitting to the event loop
- Already-cancelled tasks fail immediately without touching the event loop

### R3: Cancelled operations must not leak resources
- If a CBData is retained at cancellation time, it must be released
- If a file handle is open, it must be closed (fire-and-forget)
- The event loop's outstanding continuation count must decrement

### R4: Cancellation must not corrupt connection state
- Cancelling one operation must not tear down the entire connection
- Other in-flight operations on the same connection must continue normally
- Only the cancelled operation's continuation is affected

## Verification

- Test: start a large file read, cancel the Task after first chunk, verify `CancellationError` thrown within timeout
- Test: cancel a Task before starting an operation, verify immediate `CancellationError` (fast-path)
- Test: cancel one of two concurrent operations, verify the other completes successfully
- Test: after cancellation, verify the connection is still usable for new operations
