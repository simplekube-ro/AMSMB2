# T7: NIO TCP Transport Patterns (TCPTransportApple)

## NWError switch exhaustiveness
NWError has `.posix`, `.dns`, `.tls`, `.wifiAware` + `@unknown default`. Omitting `.wifiAware`
produces a "switch must be exhaustive" warning even with `@unknown default` present, because
`.wifiAware` is a non-unknown named case added in newer SDK.

## NIOTS connect retry on loopback
`NIOTSConnectionBootstrap` connecting to 127.0.0.1:1 (refused port) may retry for ~10 seconds
before giving up (Network.framework path evaluation). Fix: use `.connectTimeout(.seconds(Int64(n)))`
on the bootstrap. In tests: `TCPTransportApple(connectTimeoutSeconds: 2)` to make the
connect-failure test complete in ~2 s instead of 10 s.

## Public API: keep NIO types out of public init
Use `connectTimeoutSeconds: Int` (not `TimeAmount`) in the public init so callers don't need
to import NIOCore. Convert internally: `.connectTimeout(.seconds(Int64(n)))`.

## EventLoopFuture.get() is not cooperatively cancellable
`future.get()` continues waiting even when the enclosing Task is cancelled. Correct pattern:
```swift
let channel = try await withTaskCancellationHandler(
    operation: { try await future.get() },
    onCancel: { future.whenSuccess { $0.close(promise: nil) } }
)
if Task.isCancelled { channel.close(promise: nil); throw POSIXError(.ECANCELED) }
```

## InboundBufferingHandler concurrency model
- `ChannelInboundHandler` callbacks run on the NIO event loop (not the Swift actor).
- `receive()` is called from async Tasks on any executor.
- Guard ALL state with NSLock. Resume continuations OUTSIDE the lock:
  ```swift
  let cont = lock.withLock { capture; nil out field; return captured }
  cont?.resume(returning: data) // outside lock
  ```

## Cancellation in InboundBufferingHandler.receive()
```swift
withTaskCancellationHandler(
    operation: {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                if !buffer.isEmpty { ... cont.resume(returning: ...) }
                else if isEOF { cont.resume(returning: Data()) }
                else if let err = pendingError { cont.resume(throwing: err) }
                else if Task.isCancelled { cont.resume(throwing: CancellationError()) }
                else { waitingContinuation = cont }   // store under lock
            }
        }
    },
    onCancel: { [self] in
        let cont = lock.withLock { let c = waitingContinuation; waitingContinuation = nil; return c }
        cont?.resume(throwing: CancellationError())
    }
)
```
The `Task.isCancelled` check inside the continuation body closes the race where `onCancel`
fires before `waitingContinuation` is stored.

## close() idempotency
```swift
let channel: (any Channel)? = lock.withLock {
    guard !_isClosed else { return nil }
    _isClosed = true; let ch = _channel; _channel = nil; return ch
}
if let channel { try? await channel.close().get() }
inboundHandler.signalClosed()
try? await group.shutdownGracefully()
```
`signalClosed()` is a separate method that marks EOF and resumes any waiting `receive()`
continuation — needed because the channel close fires `channelInactive` only after the
channel pipeline processes it (which may be too late if the group is already shutting down).

## Test count
As of T7: 129 tests total, 44 skipped (integration, no SMB_SERVER), 0 failures.
Prior (T6): 121 tests.
