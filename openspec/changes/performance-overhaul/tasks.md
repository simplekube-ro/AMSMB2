## 1. Event Loop Core

- [ ] 1.1 Create `EventLoop` class in Context.swift with a dedicated `DispatchQueue` (serial), `DispatchSource` read/write sources on the socket fd, and start/stop lifecycle methods
- [ ] 1.2 Implement MPSC submission queue (`RequestItem` struct with closure + `CheckedContinuation`) and a signal mechanism (e.g., `DispatchSource.makeUserDataAddSource`) to wake the event loop when new items are enqueued
- [ ] 1.3 Implement the event loop drain cycle: on wake, dequeue all pending `RequestItem`s, call their libsmb2 async closures on the event loop queue, then call `smb2_service()` when socket events fire
- [ ] 1.4 Implement `CBData` continuation bridging: modify `generic_handler` to resume `CheckedContinuation` with result/error instead of setting `isFinished`; use `Unmanaged.passRetained`/`takeRetainedValue` for CBData lifetime — ensure no dangling pointer on timeout (absorbed review finding #1)
- [ ] 1.5 Implement connection error broadcast: track all outstanding continuations and resume them with the connection error when the socket drops or `smb2_service` returns an error
- [ ] 1.6 Implement graceful shutdown: on `deinit`/`disconnect`, cancel DispatchSources, drain submission queue with `CancellationError`, resume all outstanding continuations, then destroy `smb2_context`

## 2. SMB2Client Migration

- [ ] 2.1 Replace `NSRecursiveLock` + `withThreadSafeContext` + `wait_for_reply` with event loop submission in `SMB2Client`; add new `submit(_:)` async method that creates a continuation and enqueues to the event loop
- [ ] 2.2 Rewrite `async_await` and `async_await_pdu` to use `submit(_:)` — each becomes an `async throws` function that awaits the continuation result
- [ ] 2.3 Migrate all `SMB2Client` operations (connect, disconnect, echo, stat, statvfs, mkdir, rmdir, unlink, rename, truncate, shareEnum) to use the new async submission path
- [ ] 2.4 Update property accessors that call `withThreadSafeContext` (workstation, domain, user, password, securityMode, seal, authentication) to submit to the event loop for thread-safe access
- [ ] 2.5 Replace `smb2.pointee.fd` private field access with `smb2_get_fd()` public API (absorbed review finding #18)
- [ ] 2.6 Verify `SMB2Client` builds and all existing unit tests pass with the new event loop model

## 3. Buffer Pool

- [ ] 3.1 Create `BufferPool` class: array-backed pool with `checkout(minimumSize:) -> Data` and `checkin(_ buffer: Data)` methods, max pool size of 8, accessed only from event loop thread
- [ ] 3.2 Update `SMB2FileHandle.read()` and `pread()` to use `BufferPool.checkout()` instead of `Data(repeating: 0, count:)`, and return the buffer via in-place count truncation instead of `Data(buffer.prefix(...))`
- [ ] 3.3 Update `SMB2FileHandle.write()` and `pwrite()` to avoid the `Data(data)` conversion when input is already contiguous

## 4. Request Pipelining

- [ ] 4.1 Implement `pipelinedRead(handle:offset:totalLength:chunkSize:maxInFlight:)` in SMB2Client that queues up to `maxInFlight` `smb2_pread_async` calls, collects results in offset order, and replenishes the pipeline as replies arrive
- [ ] 4.2 Implement `pipelinedWrite(handle:data:offset:chunkSize:maxInFlight:)` with the same pipeline pattern for writes, including cancellation of remaining chunks on failure
- [ ] 4.3 Update `SMB2Manager`'s file read path (the `read` method that reads an entire file in chunks) to use `pipelinedRead` instead of sequential chunk reads
- [ ] 4.4 Update `SMB2Manager`'s file write path to use `pipelinedWrite` instead of sequential chunk writes
- [ ] 4.5 Update server-side copy (`copyContentsOfItem`) to pipeline copy chunks where possible

## 5. Stream Backpressure

- [ ] 5.1 Add `highWaterMark` and `lowWaterMark` parameters to `AsyncInputStream` initializer (defaults: 4 MB / 1 MB)
- [ ] 5.2 Modify `prefetchData()` to suspend (via continuation) when buffer size exceeds `highWaterMark`, and resume when `read()` drops the buffer below `lowWaterMark`
- [ ] 5.3 Ensure `_streamStatus` is accessed under lock or via atomic — eliminate the data race identified in review finding #5
- [ ] 5.4 Verify that streaming a large file via `AsyncInputStream` keeps peak memory bounded

## 6. Lazy Directory Enumeration

- [ ] 6.1 Add `contentsOfDirectory(atPath:) -> AsyncThrowingStream<[URLResourceKey: any Sendable], any Error>` overload to `SMB2Manager` that yields entries on demand via the event loop
- [ ] 6.2 Reimplement the existing eager `contentsOfDirectory(atPath:)` on top of the lazy version (collect all entries into array)
- [ ] 6.3 Implement lazy recursive listing: descend into subdirectories as encountered during iteration, not after collecting all top-level entries
- [ ] 6.4 Deprecate or remove `SMB2Directory.count` (full-scan property)

## 7. Task Cancellation

- [ ] 7.1 Wrap every `SMB2Manager` async method with `withTaskCancellationHandler` that removes the pending continuation from the event loop's tracking dictionary and resumes it with `CancellationError`
- [ ] 7.2 Add `try Task.checkCancellation()` before each event loop submission as a fast-path check
- [ ] 7.3 Ensure cancelled operations release any retained CBData and do not leak resources
- [ ] 7.4 Add test: cancel a Task mid-read, verify the operation throws `CancellationError` and does not block

## 8. AMSMB2.swift Integration

- [ ] 8.1 Update `SMB2Manager`'s `queue` dispatch model to work with the new async event loop — operations should `await` the event loop submission instead of blocking in a `DispatchQueue.async` closure
- [ ] 8.2 Eliminate the concurrent `q` queue and semaphore-based `operationLock.wait()` — replace with structured async (eliminates review findings #4 deadlock, #10 QoS mismatch)
- [ ] 8.3 Fix `connect()` to assign `self.client` only after successful connection (absorbed review finding #13)
- [ ] 8.4 Ensure `with()` helpers access `client` safely through structured async rather than unguarded reads (absorbed review finding #3)
- [ ] 8.5 Ensure `leaseData` lifetime in `SMB2FileHandle.init` is correctly extended across the async PDU submission (absorbed review finding #21)
- [ ] 8.6 Update `disconnectShare` to coordinate with the event loop shutdown (wait for pending operations, then shut down)
- [ ] 8.7 Ensure `operationCount` tracking still works correctly with the async model

## 9. Testing and Verification

- [ ] 9.1 Run full unit test suite and verify all existing tests pass
- [ ] 9.2 Run integration test suite (`make integrationtest`) against Docker SMB server and verify all tests pass
- [ ] 9.3 Verify concurrent operations on different file handles complete independently (no serialization)
- [ ] 9.4 Verify pipelined reads deliver results in correct offset order
- [ ] 9.5 Verify `AsyncInputStream` memory stays bounded during large file streaming
- [ ] 9.6 Verify graceful shutdown: all pending continuations receive errors on disconnect
- [ ] 9.7 Verify Task cancellation: cancelled reads/writes throw `CancellationError` promptly
- [ ] 9.8 Verify no data races under Swift 6 strict concurrency checking (`-strict-concurrency=complete`)
