## Why

AMSMB2's Swift wrapper serializes all SMB2 operations through a single `NSRecursiveLock` held for the entire duration of each blocking poll loop. This throws away libsmb2's built-in support for multiple in-flight requests (PDU queueing, credit tracking, message ID correlation), reducing throughput to one-request-at-a-time on every connection. On high-latency links, round-trip overhead dominates — a 10MB file read takes 10 sequential round trips instead of pipelining them. Additionally, per-read buffer allocations (zero-fill + copy), unbounded stream buffering, and eager directory enumeration add unnecessary CPU and memory overhead.

## What Changes

- **Replace synchronous poll-inside-lock with a dedicated event loop thread** that exclusively owns the libsmb2 context, services the socket, and dispatches callbacks. Swift callers submit requests and `await` Swift continuations instead of blocking threads.
- **Enable request pipelining** — multiple read/write PDUs queued and in-flight simultaneously over a single TCP connection, bounded by server-granted SMB2 credits.
- **Reusable I/O buffer pool** to eliminate per-read `Data(repeating: 0, count:)` allocation and the extra `Data(buffer.prefix(...))` copy on every chunk.
- **Reduce poll timeout** from 1 second to a smaller value, lowering worst-case per-operation latency.
- **Add backpressure to `AsyncInputStream`** so the prefetch task pauses when the internal buffer exceeds a configurable high-water mark, preventing unbounded memory growth on large file streams.
- **Lazy directory enumeration** — replace eager all-in-memory listing with an iterator/`AsyncSequence` that yields entries on demand, and eliminate the full-scan `count` property.
- **Full Task cancellation support** — wrap async operations with `withTaskCancellationHandler` for per-operation cancellation. The continuation-based model makes this natural.
- **BREAKING**: `SMB2Client.async_await` and `wait_for_reply` are replaced by the event loop submission model. Internal API only — public `SMB2Manager` API is unchanged.

### Review Findings Absorbed

This change structurally eliminates the following issues identified in a comprehensive code review (Mar 2026):

- **CBData dangling pointer after timeout** — The continuation model eliminates the `passRetained`/`takeRetainedValue` dance and the `isAbandoned` flag. Continuations are tracked in a dictionary; on timeout, the continuation is removed and resumed with an error. No retained pointers outlive their scope.
- **generic_handler fd<0 leaks CBData** — Eliminated: no `Unmanaged` retain in the new model for most paths. Continuation bridging is structured.
- **`client` accessed without connectLock** — The event loop submission model means `SMB2Client` is accessed through `submit()` not through direct property access. The `with()` helpers use structured async, not a concurrent queue with shared mutable state.
- **Graceful disconnect deadlock potential** — No more `connectLock` + `operationLock.wait()` combination. The event loop handles shutdown sequencing.
- **AsyncInputStream `_streamStatus` data race** — Backpressure rewrite uses continuation-based suspension, eliminating the split lock/non-lock access pattern.
- **QoS mismatch between `q` and `eventLoopQueue`** — The concurrent `q` queue is replaced by async/await. No more semaphore-waiting threads at mismatched QoS.
- **No Task cancellation support** — Full cancellation via `withTaskCancellationHandler` on every async operation.
- **`client` assigned before connect succeeds** — The async connect path can use a local variable and assign `self.client` only on success.
- **`smb2.pointee.fd` private field access** — Replaced by `smb2_get_fd()` API in the new SocketMonitor/event loop setup.
- **`leaseData` pointer escapes `withUnsafeMutableBytes`** — The PDU creation closure in the new submit model can capture `leaseData` directly with proper lifetime extension.

## Capabilities

### New Capabilities
- `event-loop`: Dedicated thread that owns the libsmb2 context, runs the poll/service loop, accepts requests via a thread-safe submission queue, and fulfills Swift continuations on completion.
- `request-pipelining`: Multiple SMB2 read/write requests queued and in-flight concurrently, bounded by server-granted credits, with ordered result delivery.
- `buffer-pool`: Reusable pre-allocated `Data` buffers for I/O operations, eliminating per-read zero-fill and per-result copy overhead.
- `stream-backpressure`: High-water/low-water mark flow control in `AsyncInputStream` to bound memory usage during large file streaming.
- `lazy-directory-enumeration`: On-demand directory entry iteration via `AsyncSequence`, replacing eager full-directory-in-memory listing.
- `task-cancellation`: Per-operation Swift Task cancellation via `withTaskCancellationHandler`, integrated with event loop continuation tracking.

### Modified Capabilities
<!-- No existing specs to modify -->

## Impact

- **Context.swift**: Major rewrite — `withThreadSafeContext`, `async_await`, `async_await_pdu`, `wait_for_reply`, and the `NSRecursiveLock` are replaced by event loop submission.
- **FileHandle.swift**: `read`/`pread`/`write`/`pwrite` adapted to submit requests to the event loop and use pooled buffers.
- **Stream.swift**: `AsyncInputStream` gains backpressure with high-water/low-water marks.
- **Directory.swift**: `SMB2Directory` iterator reworked for lazy evaluation; `count` property behavior changes.
- **AMSMB2.swift**: Internal call sites updated to use new async submission model. Public API signatures unchanged.
- **Threading model**: Shifts from "concurrent DispatchQueue serialized by lock" to "dedicated event loop thread + Swift continuations". Callers no longer block threads waiting for SMB2 replies.
