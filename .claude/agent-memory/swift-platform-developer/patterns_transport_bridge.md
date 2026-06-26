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

## Lock All Mutable State — Including Task References

**Rule**: When a type is `@unchecked Sendable` with a doc comment claiming "all mutable state is
guarded by NSLock", EVERY mutable var must be guarded — including `Task<Void,Never>?` references.

`outboundPumpTask` and `inboundPumpTask` are written in `startOutboundPump()`/`startInboundPump()`
and read (+ cancelled) in `close()`. These cross-thread accesses require lock protection.

**Pattern**:
```swift
// Assign under lock, create Task outside lock only if needed (Task() is non-blocking):
func startOutboundPump() {
    lock.lock()
    defer { lock.unlock() }
    guard outboundPumpTask == nil else { return }   // double-start guard
    outboundPumpTask = Task { [self] in await outboundPump() }
}

// In close(): read+nil under lock, cancel outside:
lock.lock()
let capturedOutbound = outboundPumpTask
outboundPumpTask = nil
lock.unlock()
capturedOutbound?.cancel()   // outside lock — cancel is safe anywhere
```

The double-start guard (`guard pumpTask == nil else { return }`) prevents task leaks when
start helpers are called more than once (test-only scenario, low production risk).

## ByteFIFO Inlining Note

Design D3 originally sketched a distinct `ByteFIFO` type. In the actual implementation it was
inlined directly into `TransportBridge` (avoids extra abstraction, no dead code concern).
Document this in design.md so artifacts match implementation (per CLAUDE.md).

## Platform Guard

`TransportBridge.swift` wrapped in `#if canImport(Network)`. Tests also guarded.
Linux build: bridge is excluded (no `TCPTransportApple` production conformer on Linux anyway).
