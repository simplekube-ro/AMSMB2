# BufferPool Raw Pointer Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Eliminate undefined behavior where `Data.withUnsafeMutableBytes` pointers escape their closure scope and are held by libsmb2 across async suspension points.

**Architecture:** Replace `BufferPool`'s `Data`-based storage with `UnsafeMutableRawPointer`-based `RawBuffer` values. Callers pass `buffer.pointer` directly to libsmb2 (no `withUnsafeMutableBytes` needed). The pointer is valid for the entire scope because we own it. A `Data` copy is created only at the end for the return value.

**Tech Stack:** Swift, libsmb2 C interop, `UnsafeMutableRawPointer`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `AMSMB2/Context.swift` | Modify lines 13–48 | `BufferPool` class: change from `[Data]` pool to `[RawBuffer]` pool |
| `AMSMB2/FileHandle.swift` | Modify `read()`, `pread()`, `pipelinedRead()` | Switch from `Data` + `withUnsafeMutableBytes` to `RawBuffer` + direct pointer |
| `AMSMB2Tests/SMB2TypeTests.swift` | Add tests | Unit tests for `BufferPool` and `RawBuffer` |

No new files. No public API changes.

---

### Task 1: Add BufferPool unit tests (Red)

**Files:**
- Modify: `AMSMB2Tests/SMB2TypeTests.swift`

- [x] **Step 1: Write failing tests for the new RawBuffer-based BufferPool**

Add these tests at the end of `SMB2TypeTests`:

```swift
// MARK: - BufferPool

func testBufferPoolCheckoutReturnsRequestedSize() {
    let pool = BufferPool()
    let buf = pool.checkout(minimumSize: 1024)
    XCTAssertGreaterThanOrEqual(buf.capacity, 1024)
    XCTAssertNotNil(buf.pointer)
    pool.checkin(buf)
}

func testBufferPoolReusesReturnedBuffer() {
    let pool = BufferPool()
    let buf1 = pool.checkout(minimumSize: 512)
    let ptr1 = buf1.pointer
    pool.checkin(buf1)

    let buf2 = pool.checkout(minimumSize: 512)
    XCTAssertEqual(buf2.pointer, ptr1, "Pool should return the same buffer when size fits")
    pool.checkin(buf2)
}

func testBufferPoolDiscardsWhenFull() {
    let pool = BufferPool(maxPoolSize: 2)
    let bufs = (0..<3).map { _ in pool.checkout(minimumSize: 64) }
    for buf in bufs { pool.checkin(buf) }
    // Pool holds at most 2; third is discarded (deallocated).
    // Just verify no crash — the discarded buffer's memory is freed.
    let buf = pool.checkout(minimumSize: 64)
    XCTAssertGreaterThanOrEqual(buf.capacity, 64)
    pool.checkin(buf)
}

func testBufferPoolResizesSmallBuffer() {
    let pool = BufferPool()
    let small = pool.checkout(minimumSize: 64)
    pool.checkin(small)

    // Request larger than what's pooled — pool should resize or allocate fresh.
    let big = pool.checkout(minimumSize: 4096)
    XCTAssertGreaterThanOrEqual(big.capacity, 4096)
    pool.checkin(big)
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-sandbox --filter SMB2TypeTests/testBufferPool`
Expected: FAIL — `BufferPool.checkout` returns `Data`, not a type with `.pointer` and `.capacity`.

---

### Task 2: Rewrite BufferPool to use RawBuffer (Green)

**Files:**
- Modify: `AMSMB2/Context.swift` (lines 13–48)

- [x] **Step 3: Replace BufferPool implementation**

Replace the entire `BufferPool` class (lines 13–48 of Context.swift) with:

```swift
/// Fixed-capacity raw memory buffer managed by `BufferPool`.
/// The pointer is stable for the lifetime of the `RawBuffer` — safe to pass
/// to C APIs that hold it across async suspension points.
struct RawBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let capacity: Int

    fileprivate init(capacity: Int) {
        self.pointer = .allocate(byteCount: capacity, alignment: 1)
        self.capacity = capacity
    }

    fileprivate func deallocate() {
        pointer.deallocate()
    }

    /// Creates a `Data` by copying `count` bytes from the buffer.
    func data(count: Int) -> Data {
        Data(bytes: pointer, count: min(count, capacity))
    }
}

/// Reusable fixed-capacity buffer pool. Avoids per-operation allocation by
/// recycling `RawBuffer` instances between calls. Thread-safe via an internal lock.
final class BufferPool: @unchecked Sendable {
    private var pool: [RawBuffer] = []
    private let maxPoolSize: Int
    private let poolLock = NSLock()

    init(maxPoolSize: Int = 8) {
        self.maxPoolSize = maxPoolSize
    }

    /// Returns a buffer of at least `minimumSize` bytes.
    /// Prefers a pooled buffer that is already large enough; otherwise
    /// deallocates the largest available pooled buffer and allocates fresh.
    func checkout(minimumSize: Int) -> RawBuffer {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let index = pool.lastIndex(where: { $0.capacity >= minimumSize }) {
            return pool.remove(at: index)
        }
        // No buffer large enough — discard any pooled buffer and allocate fresh.
        if let index = pool.indices.last {
            pool.remove(at: index).deallocate()
        }
        return RawBuffer(capacity: minimumSize)
    }

    /// Returns a buffer to the pool. Buffers beyond `maxPoolSize` are deallocated.
    func checkin(_ buffer: RawBuffer) {
        poolLock.lock()
        defer { poolLock.unlock() }
        guard pool.count < maxPoolSize else {
            buffer.deallocate()
            return
        }
        pool.append(buffer)
    }

    deinit {
        for buffer in pool { buffer.deallocate() }
    }
}
```

Key differences from old implementation:
- Pool stores `[RawBuffer]` not `[Data]`
- `checkout` returns `RawBuffer` (has `.pointer` and `.capacity`)
- When no large-enough buffer exists, the old version resized a `Data` in-place. That doesn't work with raw pointers (can't resize). Instead, we deallocate the pooled buffer and allocate fresh.
- `checkin` deallocates the buffer (instead of just dropping it) when the pool is full.
- `deinit` deallocates all pooled buffers to prevent leaks.
- `RawBuffer.data(count:)` is the only place a `Data` copy is created.

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --filter SMB2TypeTests/testBufferPool`
Expected: 4 tests PASS

- [x] **Step 5: Commit**

```
git add AMSMB2/Context.swift AMSMB2Tests/SMB2TypeTests.swift
git commit -m "refactor: rewrite BufferPool to use RawBuffer with stable pointer lifetime"
```

---

### Task 3: Update read() and pread() to use RawBuffer

**Files:**
- Modify: `AMSMB2/FileHandle.swift` — `read()` (~line 243) and `pread()` (~line 265)

- [x] **Step 6: Update `read()` to use RawBuffer**

Replace the current `read()` body (from `let count =` through `return Data(...)`) with:

```swift
    func read(length: Int = 0) async throws -> Data {
        precondition(
            length <= UInt32.max, "Length bigger than UInt32.max can't be handled by libsmb2."
        )

        let handle = try handle.unwrap()
        let count = length > 0 ? length : optimizedReadSize
        let buffer = client.bufferPool.checkout(minimumSize: count)
        defer { client.bufferPool.checkin(buffer) }
        let result = try await client.async_await { context, cbPtr -> Int32 in
            smb2_read_async(
                context, handle, buffer.pointer, .init(count), SMB2Client.generic_handler, cbPtr
            )
        }
        return buffer.data(count: Int(result))
    }
```

Changes:
- `var buffer = ... Data` → `let buffer = ... RawBuffer`
- No `buffer.count = count` (RawBuffer has fixed capacity)
- No `withUnsafeMutableBytes` — pass `buffer.pointer` directly
- `Data(buffer.prefix(...))` → `buffer.data(count:)`

- [x] **Step 7: Update `pread()` to use RawBuffer**

Same pattern:

```swift
    public func pread(offset: UInt64, length: Int = 0) async throws -> Data {
        precondition(
            length <= UInt32.max, "Length bigger than UInt32.max can't be handled by libsmb2."
        )

        let handle = try handle.unwrap()
        let count = length > 0 ? length : optimizedReadSize
        let buffer = client.bufferPool.checkout(minimumSize: count)
        defer { client.bufferPool.checkin(buffer) }
        let result = try await client.async_await { context, cbPtr -> Int32 in
            smb2_pread_async(
                context, handle, buffer.pointer, .init(count), offset, SMB2Client.generic_handler,
                cbPtr
            )
        }
        return buffer.data(count: Int(result))
    }
```

- [x] **Step 8: Build and run full test suite**

Run: `swift test --disable-sandbox`
Expected: 81 tests PASS, 0 failures

- [x] **Step 9: Commit**

```
git add AMSMB2/FileHandle.swift
git commit -m "refactor: use RawBuffer in read/pread for safe pointer lifetime"
```

---

### Task 4: Update pipelinedRead() to use RawBuffer

**Files:**
- Modify: `AMSMB2/FileHandle.swift` — `pipelinedRead()` (~line 340)

- [x] **Step 10: Update pipelinedRead task body**

Inside `pipelinedRead`, each `group.addTask` currently does:

```swift
var buffer = client.bufferPool.checkout(minimumSize: chunkLen)
defer { client.bufferPool.checkin(buffer) }
buffer.count = chunkLen
let bytesRead = try await client.async_await { context, cbPtr -> Int32 in
    buffer.withUnsafeMutableBytes { buf in
        smb2_pread_async(context, fh, buf.baseAddress, .init(buf.count), ...)
    }
}
return (i, Data(buffer.prefix(Int(bytesRead))))
```

Replace with:

```swift
let buffer = client.bufferPool.checkout(minimumSize: chunkLen)
defer { client.bufferPool.checkin(buffer) }
let bytesRead = try await client.async_await { context, cbPtr -> Int32 in
    smb2_pread_async(
        context, fh, buffer.pointer, .init(chunkLen),
        chunkOffset, SMB2Client.generic_handler, cbPtr
    )
}
return (i, buffer.data(count: Int(bytesRead)))
```

Changes: same pattern as Task 3 — `RawBuffer` with direct `.pointer` access.

Note: the `fh` variable inside the task is reconstructed from `rawHandle` via `OpaquePointer(bitPattern: rawHandle)` — keep that unchanged.

- [x] **Step 11: Build and run full test suite**

Run: `swift test --disable-sandbox`
Expected: 81 tests PASS, 0 failures

- [x] **Step 12: Commit**

```
git add AMSMB2/FileHandle.swift
git commit -m "refactor: use RawBuffer in pipelinedRead for safe pointer lifetime"
```

---

### Task 5: Final verification

**Files:** None (verification only)

- [x] **Step 13: Verify no remaining withUnsafeMutableBytes in read paths**

Run: `grep -n 'withUnsafeMutableBytes' AMSMB2/FileHandle.swift`

Expected: Zero matches. All `withUnsafeMutableBytes` calls in read/pread paths should be gone. (Write paths don't use the buffer pool — they use `Data.withUnsafeBytes` which is safe because writes are synchronous: the pointer is used inside the handler closure that runs on the event loop queue, and the closure returns before the `withUnsafeBytes` scope ends.)

- [x] **Step 14: Verify strict concurrency still clean**

Run: `swift build --disable-sandbox -Xswiftc -strict-concurrency=complete 2>&1 | grep error:`
Expected: No errors.

- [x] **Step 15: Run full test suite one final time**

Run: `swift test --disable-sandbox`
Expected: 81 tests PASS, 0 failures

- [x] **Step 16: Commit if any final adjustments were needed, otherwise done**
