## 1. Event Loop Core

- [x] 1.1 Create `EventLoop` class in Context.swift with a dedicated `DispatchQueue` (serial), `DispatchSource` read/write sources on the socket fd, and start/stop lifecycle methods
- [x] 1.2 Implement MPSC submission queue (`RequestItem` struct with closure + `CheckedContinuation`) and a signal mechanism (e.g., `DispatchSource.makeUserDataAddSource`) to wake the event loop when new items are enqueued
- [x] 1.3 Implement the event loop drain cycle: on wake, dequeue all pending `RequestItem`s, call their libsmb2 async closures on the event loop queue, then call `smb2_service()` when socket events fire
- [x] 1.4 Implement `CBData` continuation bridging: modify `generic_handler` to resume `CheckedContinuation` with result/error instead of setting `isFinished`; use `Unmanaged.passRetained`/`takeRetainedValue` for CBData lifetime
- [x] 1.5 Implement connection error broadcast: track all outstanding continuations and resume them with the connection error when the socket drops or `smb2_service` returns an error
- [x] 1.6 Implement graceful shutdown: on `deinit`/`disconnect`, cancel DispatchSources, drain submission queue with `CancellationError`, resume all outstanding continuations, then destroy `smb2_context`

## 2. SMB2Client Migration

- [x] 2.1 Replace `NSRecursiveLock` + `withThreadSafeContext` + `wait_for_reply` with event loop submission in `SMB2Client`; add new `submit(_:)` async method that creates a continuation and enqueues to the event loop
- [x] 2.2 Rewrite `async_await` and `async_await_pdu` to use `submit(_:)` — each becomes an `async throws` function that awaits the continuation result
- [x] 2.3 Migrate all `SMB2Client` operations (connect, disconnect, echo, stat, statvfs, mkdir, rmdir, unlink, rename, truncate, shareEnum) to use the new async submission path
- [x] 2.4 Update property accessors that call `withThreadSafeContext` (workstation, domain, user, password, securityMode, seal, authentication) to submit to the event loop for thread-safe access
- [x] 2.5 Verify `SMB2Client` builds and all existing unit tests pass with the new event loop model

## 3. Buffer Pool

- [x] 3.1 Create `BufferPool` class: array-backed pool with `checkout(minimumSize:) -> Data` and `checkin(_ buffer: Data)` methods, max pool size of 8, accessed only from event loop thread
- [x] 3.2 Update `SMB2FileHandle.read()` and `pread()` to use `BufferPool.checkout()` instead of `Data(repeating: 0, count:)`, and return the buffer via in-place count truncation instead of `Data(buffer.prefix(...))`
- [x] 3.3 Update `SMB2FileHandle.write()` and `pwrite()` to avoid the `Data(data)` conversion when input is already contiguous

## 4. Request Pipelining

- [x] 4.1 Implement `pipelinedRead(handle:offset:totalLength:chunkSize:maxInFlight:)` in SMB2Client that queues up to `maxInFlight` `smb2_pread_async` calls, collects results in offset order, and replenishes the pipeline as replies arrive
- [x] 4.2 Implement `pipelinedWrite(handle:data:offset:chunkSize:maxInFlight:)` with the same pipeline pattern for writes, including cancellation of remaining chunks on failure
- [x] 4.3 Update `SMB2Manager`'s file read path (the `read` method that reads an entire file in chunks) to use `pipelinedRead` instead of sequential chunk reads
- [x] 4.4 Update `SMB2Manager`'s file write path to use `pipelinedWrite` instead of sequential chunk writes
- [x] 4.5 Update server-side copy (`copyContentsOfItem`) to pipeline copy chunks where possible

## 5. Stream Backpressure

- [x] 5.1 Add `highWaterMark` and `lowWaterMark` parameters to `AsyncInputStream` initializer (defaults: 4 MB / 1 MB)
- [x] 5.2 Modify `prefetchData()` to suspend (via continuation) when buffer size exceeds `highWaterMark`, and resume when `read()` drops the buffer below `lowWaterMark`
- [x] 5.3 Verify that streaming a large file via `AsyncInputStream` keeps peak memory bounded

## 6. Lazy Directory Enumeration

- [x] 6.1 Add `contentsOfDirectory(atPath:) -> AsyncThrowingStream<[URLResourceKey: any Sendable], any Error>` overload to `SMB2Manager` that yields entries on demand via the event loop
- [x] 6.2 Reimplement the existing eager `contentsOfDirectory(atPath:)` on top of the lazy version (collect all entries into array)
- [x] 6.3 Implement lazy recursive listing: descend into subdirectories as encountered during iteration, not after collecting all top-level entries
- [x] 6.4 Deprecate or remove `SMB2Directory.count` (full-scan property)

## 7. AMSMB2.swift Integration

- [x] 7.1 Update `SMB2Manager`'s `queue` dispatch model to work with the new async event loop — operations should `await` the event loop submission instead of blocking in a `DispatchQueue.async` closure
- [x] 7.2 Update `disconnectShare` to coordinate with the event loop shutdown (wait for pending operations, then shut down)
- [x] 7.3 Ensure `operationCount` tracking still works correctly with the async model

## 8. Testing and Verification

- [x] 8.1 Run full unit test suite and verify all existing tests pass
- [x] 8.2 Run integration test suite (`make integrationtest`) against Docker SMB server and verify all tests pass
- [x] 8.3 Verify concurrent operations on different file handles complete independently (no serialization)
- [x] 8.4 Verify pipelined reads deliver results in correct offset order
- [x] 8.5 Verify `AsyncInputStream` memory stays bounded during large file streaming
- [x] 8.6 Verify graceful shutdown: all pending continuations receive errors on disconnect
