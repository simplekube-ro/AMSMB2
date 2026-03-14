## Context

AMSMB2 wraps libsmb2 (a C library) to provide SMB2/3 operations on Apple platforms and Linux. The current architecture uses a single `NSRecursiveLock` in `SMB2Client` (Context.swift) that serializes all operations through a blocking `poll()` loop. Each operation acquires the lock, calls a `smb2_*_async()` function, then spins in `wait_for_reply()` polling the socket until the callback fires. This design:

- Blocks one thread per operation for the entire round-trip
- Prevents concurrent operations even though libsmb2's PDU queue supports multiple in-flight requests
- Adds up to 1 second of latency per poll timeout cycle
- Allocates and zero-fills a new `Data` buffer per read, then copies the result into a second `Data`
- Buffers all `AsyncInputStream` data in memory without backpressure
- Loads entire directories eagerly into memory

libsmb2 itself supports: PDU queueing (outqueue/waitqueue), credit-based flow control (up to 1024 credits), message ID correlation for out-of-order replies, and processing multiple replies per `smb2_service()` call.

## Goals / Non-Goals

**Goals:**
- Replace the lock-and-poll model with a dedicated event loop thread that exclusively owns the `smb2_context`
- Enable multiple SMB2 requests in-flight simultaneously (pipelining), bounded by server-granted credits
- Eliminate per-read buffer allocation overhead with a reusable buffer pool
- Add backpressure to `AsyncInputStream` to bound memory usage
- Replace eager directory loading with lazy `AsyncSequence`-based enumeration
- Reduce poll timeout to lower worst-case per-operation latency
- Preserve the public `SMB2Manager` API — no breaking changes for consumers

**Non-Goals:**
- Multi-channel support (multiple TCP connections) — libsmb2 doesn't implement it
- SMB2 compounding (chaining operations in a single message) — protocol support exists in libsmb2 but is not actively used; too complex for this change
- Connection pooling at the `SMB2Manager` level
- Changing the libsmb2 C library itself

## Decisions

### D1: Event loop thread model — dedicated `Thread` with `DispatchSource` for socket readability

**Choice**: A single dedicated thread per `SMB2Client` that owns the `smb2_context` and uses `DispatchSource.makeReadSource()` / `DispatchSource.makeWriteSource()` on the socket fd. Callers submit work items (closures that call `smb2_*_async`) via a thread-safe queue and receive results through Swift `CheckedContinuation`.

**Alternatives considered**:
- *Keep the lock, batch requests inside it* — simpler but still blocks threads; doesn't integrate with Swift concurrency
- *Use `CFRunLoop` with `CFSocket`* — platform-specific, less portable to Linux
- *Use a bare `pthread` with `poll()`* — works on Linux but loses GCD integration and `DispatchSource` efficiency

**Rationale**: `DispatchSource` is available on both Apple platforms and Linux (via swift-corelibs-libdispatch). It avoids the 1-second poll timeout entirely — the kernel notifies us when the socket is readable/writable. The dedicated thread ensures all `smb2_context` access is single-threaded without locks, which is what libsmb2 expects.

### D2: Request submission — lock-free MPSC queue with continuation tracking

**Choice**: Callers submit `RequestItem` structs (containing the libsmb2 async call closure + a `CheckedContinuation`) to a lock-free MPSC (multi-producer, single-consumer) queue. The event loop thread drains this queue each iteration, calls the libsmb2 async functions, and stores the continuation in a dictionary keyed by the `CBData` identity.

**Alternatives considered**:
- *Use `DispatchQueue` as the submission mechanism* — simpler but adds GCD overhead per request
- *Use `NSCondition` + array* — works but less efficient under contention

**Rationale**: MPSC queue gives O(1) enqueue from any thread with no lock contention. The event loop is the sole consumer, so dequeue is trivially safe. This is the standard pattern for high-performance event loops.

### D3: Continuation bridging — `CheckedContinuation` per request

**Choice**: Each request carries a `CheckedContinuation<(Int32, UnsafeMutableRawPointer?), any Error>`. The generic callback (`generic_handler`) is modified to resume the continuation instead of setting `isFinished = true`. Result data handlers still run synchronously in the callback.

**Rationale**: `CheckedContinuation` integrates with Swift's structured concurrency, enables proper cancellation propagation, and catches programmer errors (double-resume) in debug builds.

### D4: Buffer pool — per-client pool of pre-allocated `Data` buffers

**Choice**: A simple pool (`BufferPool`) that maintains an array of `Data` buffers sized to `maxReadSize`. `checkout()` returns an existing buffer (resized if needed) or creates one. `checkin()` returns it to the pool. Pool size is bounded (e.g., max 8 buffers) to avoid unbounded memory growth.

**Alternatives considered**:
- *Global shared pool* — introduces contention across connections
- *`UnsafeMutableRawBufferPointer` pool* — avoids `Data` COW overhead but complicates memory management and requires manual lifecycle tracking

**Rationale**: Per-client pool avoids cross-connection contention. `Data` is already used throughout the API, so sticking with `Data` avoids a large refactor. The pool eliminates zero-fill on every read and the extra copy in `Data(buffer.prefix(...))` by using `buffer.count = result` (in-place truncation).

### D5: Stream backpressure — high-water / low-water marks

**Choice**: `AsyncInputStream.prefetchData()` pauses (via `Task` suspension) when the buffer exceeds a configurable high-water mark (default: 4 MB) and resumes when consumed below a low-water mark (default: 1 MB). Uses a `CheckedContinuation` to suspend the prefetch task.

**Rationale**: Simple and effective. The high-water mark bounds peak memory usage. The low-water mark prevents oscillation (repeatedly hitting the limit on every chunk).

### D6: Lazy directory enumeration — `AsyncSequence` yielding entries on demand

**Choice**: Add a new `listDirectory` overload that returns `AsyncThrowingStream<[URLResourceKey: any Sendable], any Error>`. Internally, it opens the directory, yields entries one by one via the event loop, and closes on completion or cancellation. The existing eager `listDirectory` is reimplemented on top of the lazy version for backward compatibility.

**Alternatives considered**:
- *Replace eager API entirely* — breaking change
- *Pagination with batch size* — adds API complexity

**Rationale**: `AsyncThrowingStream` is idiomatic Swift, composes well with `for await`, and naturally supports cancellation. Backward compatibility is preserved.

### D7: Poll timeout — eliminated by `DispatchSource`

**Choice**: The `DispatchSource`-based event loop replaces `poll()` entirely. There is no timeout to tune — the kernel wakes the event loop when the socket has data.

**Rationale**: This is a natural consequence of D1. `DispatchSource` is more efficient than `poll()` because it doesn't require periodic wakeups.

## Risks / Trade-offs

**[Risk] Event loop thread lifecycle complexity** → Careful shutdown sequencing: cancel all pending continuations with `CancellationError`, drain the submission queue, tear down `DispatchSource`, then release the `smb2_context`. The `deinit` path must handle this gracefully.

**[Risk] Callback data lifetime with continuations** → `CBData` must be retained until the continuation resumes. Use `Unmanaged.passRetained()` when submitting to libsmb2, `takeRetainedValue()` in the callback. This changes from the current `passUnretained` pattern.

**[Risk] Error propagation for pipelined requests** → If a connection drops mid-pipeline, all pending continuations must be failed. The event loop must track all outstanding continuations and resume them with the connection error.

**[Risk] Buffer pool thread safety** → The pool is only accessed from the event loop thread (checkout on callback, checkin on request completion), so no additional synchronization is needed beyond the event loop's single-threaded guarantee.

**[Risk] `SMB2Directory.count` behavioral change** → Lazy enumeration means `count` either requires consuming the full sequence (expensive) or is removed. Decision: deprecate `count` on the internal `SMB2Directory` type. The public API (`contentsOfDirectory`) already returns `[[URLResourceKey: any Sendable]]`, so callers use `.count` on that array.

**[Trade-off] Complexity increase** → The event loop + continuation model is more complex than lock + poll. But it's a well-understood pattern (used by NIO, libdispatch, libuv), and the performance gain is substantial.

**[Trade-off] Buffer pool memory overhead** → Idle buffers consume memory (up to 8 × maxReadSize ≈ 8 MB for typical 1MB read sizes). Acceptable for the throughput gain; pool auto-shrinks on `checkin()` if above max count.
