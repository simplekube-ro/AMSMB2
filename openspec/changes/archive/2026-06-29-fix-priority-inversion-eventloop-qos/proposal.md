## Why

The Thread Performance Checker flags a priority inversion in `SMB2Client.async_await()`. Callers (e.g., `pread`) run at User-initiated QoS and block on a semaphore that is signaled by `generic_handler` on `eventLoopQueue`. Since `eventLoopQueue` is created at Default QoS, the higher-priority calling thread waits on a lower-priority queue — a classic priority inversion. This causes unnecessary latency for user-facing file operations like video playback and file browsing.

## What Changes

- Elevate the `eventLoopQueue` QoS from `.default` (implicit) to `.userInitiated` when constructing `SMB2Client` in `Context.swift`.
- This is a single-line change: add `qos: .userInitiated` to the `DispatchQueue` initializer.

## Capabilities

### New Capabilities
- `eventloop-qos`: Ensures the SMB2 event loop dispatch queue runs at a QoS level that prevents priority inversion with calling threads.

### Modified Capabilities

## Impact

- **Code**: `AMSMB2/Context.swift` — `SMB2Client.init(timeout:)`, line ~83.
- **Runtime behavior**: The event loop thread will be scheduled at `.userInitiated` instead of `.default`, eliminating Thread Performance Checker warnings and reducing latency when callers operate at `.userInitiated` or higher.
- **Risk**: Minimal. Elevating QoS only affects scheduler priority; it does not change threading semantics, serialization, or API surface.
