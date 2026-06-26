# TransportBridge Patterns (T5 / #24)

## Summary

`AMSMB2/TransportBridge.swift` — bridges libsmb2's synchronous C external-transport callbacks
to an `async SMBTransport`. Guarded by `#if canImport(Network)` per design D7.

## Key Gotchas

### NSLock unavailable in async function bodies (Swift 6)

`NSLock.lock()` / `.unlock()` have `@available(*, noasync)` in Swift 6. The error:
> "instance method 'lock' is unavailable from asynchronous contexts"

**Fix**: Extract ALL lock sections into **synchronous (non-async) helper methods**. Call those
helpers from async functions. The helpers can safely call `lock.lock()` because THEY are not async.

```swift
// WRONG — direct lock.lock() in async function:
private func takeOutboundChunk() async -> Data? {
    lock.lock()  // ERROR: unavailable from async context
    ...
}

// RIGHT — synchronous helper wraps the lock:
private func dequeueFirstOutbound() -> OutboundDequeueResult {
    lock.lock()  // OK: this is a synchronous method
    defer { lock.unlock() }
    ...
}

private func takeOutboundChunk() async -> Data? {
    switch dequeueFirstOutbound() { ... }  // OK: calling sync method from async is fine
}
```

### MockTransport loopback contention with both pumps

`MockTransport.send(_:)` delivers bytes directly to a suspended `receive()` caller. When both
bridge pumps run:
- The **inbound pump** is always waiting in `transport.receive()` (= `mock.receive()`).
- The **outbound pump** calls `transport.send(data)` (= `mock.send(data)`).
- `mock.send` delivers to the **inbound pump's waiting receive()**, not to the test's `mock.receive()`.
- The test's `await mock.receive()` hangs indefinitely.

**Fix**: Use selective pump startup in tests:
- `startOutboundPump()` — for tests that verify outbound delivery via `mock.receive()`.
- `startInboundPump()` — for tests that push bytes via `mock.send()` and drain via `ext.recv`.
- `startPumps()` — for full loopback tests: C send → outbound → mock → inbound → C recv.

## Unmanaged Lifetime Discipline

```swift
// In makeExternalTransport():
ext.userdata = Unmanaged.passRetained(self).toOpaque()  // retain count + 1

// In connect/send/recv trampolines (non-owning borrow):
let bridge = Unmanaged<TransportBridge>.fromOpaque(userdata).takeUnretainedValue()

// In close trampoline (consumes the passRetained):
let bridge = Unmanaged<TransportBridge>.fromOpaque(userdata).takeRetainedValue()
bridge.close()
// When `bridge` goes out of scope: ARC releases → net effect = passRetained balanced
```

`makeExternalTransport()` must be called exactly once per bridge; the close trampoline balances
exactly once.

## Outbound Pump Cancellation Race

When `bridge.close()` runs:
1. Takes `outboundContinuation` under lock → resumes with nil.
2. Calls `outboundPumpTask?.cancel()`.

If the pump stored its continuation AFTER close() ran step 1 (race), the pump checks
`Task.isCancelled || isClosed` in `storeContinuationOrDequeue()` and resumes with nil.

The `onCancel` handler also calls `swapOutboundContinuation()?.resume(returning: nil)`. If the
continuation was already taken by close(), it's nil — no double-resume.

## Platform Guard

`TransportBridge.swift` wrapped in `#if canImport(Network)`. Tests also guarded.
Linux build: bridge is excluded (no `TCPTransportApple` production conformer on Linux anyway).
