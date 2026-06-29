## Why

Streamed uploads through `AsyncInputStream` **truncate at ~5 MiB**. Any
`write(stream:toPath:)` whose source is larger than the in-memory prefetch window silently uploads
only the first chunk and then reports success, so the destination file is short and the byte-equal
round-trip fails. This is a data-loss bug: the API reports success while dropping the tail of the
payload.

The transport seam (`feat/tcp-transport-rollout`) exposed it. On Apple every connection now routes
through the async seam, whose `send()` timing drains the stream faster than the legacy
libsmb2-owned socket did. The slower legacy consumer kept the prefetch producer permanently ahead
of the reader, masking the latent race; the seam removes that accidental cushion. This is the
"`AsyncInputStream` premature EOF when consumed faster than prefetch fills" hazard already noted in
CLAUDE.md, now a hard failure.

### Confirmed root cause (diagnosed first-hand against live Samba)

`AMSMB2/Stream.swift` → `AsyncInputStream.read(_:maxLength:)` sets `_streamStatus = .atEnd`
**whenever the consumer drains the currently-buffered bytes** (`bufferOffset == buffer.count`),
without checking whether the underlying `AsyncSequence` producer has actually finished. This
conflates two distinct conditions:

- "the consumer momentarily caught up to the prefetcher" (transient — more bytes are coming), and
- "the producer's `iterator.next()` returned `nil`" (terminal — the source is exhausted).

`prefetchData()` pauses at the high-water mark (4 MiB) and the consumer drains that plus the
~1 MiB low-water window (~5 MiB total). If the consumer reaches the buffer end before the next
chunk is appended, `read()` flips to `.atEnd`, the next `read()` returns `0`, and the consumer
(`write(client:from:toPath:)`) treats `0` as clean EOF and stops — truncating the upload at exactly
`5242880` bytes.

**Evidence:** `SMB2ManagerTests.testStreamUploadDownload` uploads `"5242880 of <N>"` for files
`> 5 MiB` and the byte-equal assertion fails; files `< 5 MiB` pass (they fit inside one prefetch
window, so the producer finishes before the consumer drains). The seam's data-API path
(`SMB2SeamIntegrationTests.testLargeWriteThenRead`, 5 MiB+7) round-trips fine over the *same* seam,
proving the defect is in the stream helper, not in seam I/O.

## What Changes

- **Track real producer completion.** `prefetchData()` sets a `producerFinished` flag (under
  `bufferLock`) **only** when `iterator.next()` returns `nil` (the prefetch loop exits normally).
- **Report EOF only when the producer is exhausted.** `read(_:maxLength:)` sets `_streamStatus =
  .atEnd` (and returns `0`) only when `bufferOffset == buffer.count && producerFinished`. When the
  buffer is drained but the producer has **not** finished, `read()` leaves the status `.open` and
  returns `-1` (would-block) so the consumer retries until more bytes arrive or the producer truly
  finishes.
- **Honor the would-block contract at the consumer.** `write(client:from:toPath:)` (and the
  `readData(maxLength:)` helper it calls) must treat a `-1` return as *would-block* (retry after
  yielding), not as a hard error — while still surfacing a genuine producer error
  (`_streamStatus == .error`, `streamError != nil`) as a thrown `POSIXError`. EOF is `0`.
- **Preserve the error path.** A producer throw still sets `_streamStatus = .error` and the
  consumer still throws the stored `streamError`.

### Non-Goals

- **No transport / seam change.** The seam, bridge, and `Context.swift` connect path are untouched;
  this fix is confined to the streaming helper and its single consumer.
- **No public API change.** `write(stream:toPath:)` and friends keep their signatures.
- **No Linux-specific change.** `AsyncInputStream` is platform-agnostic; the fix applies uniformly.
- **No backpressure-tuning change.** High/low-water marks and the prefetch pump architecture are
  unchanged except for the `producerFinished` signal.

## Capabilities

### New Capabilities

- `stream-eof-semantics`: the testable contract that `AsyncInputStream` reports EOF (`read` → `0`,
  status `.atEnd`) **only** after the producer is exhausted; that a transient buffer-drain reports
  would-block (`-1`) and the consumer retries; that a producer error surfaces as a thrown error;
  and that a streamed upload of `N` bytes (including `N > 5 MiB`) transfers all `N` bytes and
  round-trips byte-equal.

## Impact

- **`AMSMB2/Stream.swift`** (`AsyncInputStream`): add a `producerFinished` Bool guarded by
  `bufferLock`; set it in `prefetchData()` when the iterator drains; gate the `.atEnd` transition
  in `read(_:maxLength:)` on it; return `-1` (would-block) instead of `.atEnd`/`0` while the
  producer is still running.
- **`AMSMB2/AMSMB2.swift`** (`write(client:from:toPath:)`, ~line 1802) and the
  `InputStream.readData(maxLength:)` helper in `Stream.swift`: distinguish would-block (`-1`,
  status `.open`/`.reading`, `streamError == nil`) from a real error (`-1`/`.error`,
  `streamError != nil`). On would-block, yield and retry; on EOF (`0`), break; on error, throw.
- **Concurrency**: unchanged isolation model. `producerFinished` is read/written only under
  `bufferLock`; the lock is never held across `await` (the existing `bufferLock.withLock { ... }`
  discipline is preserved). The consumer's retry uses `await Task.yield()` outside any lock.
- **Tests**: `SMB2ManagerTests.testStreamUploadDownload` (random sizes, must exercise `> 5 MiB`) is
  the red→green gate, plus focused unit tests on the EOF/would-block state machine. A Docker-backed
  live Samba run of the **full** integration suite through the seam, with the streaming test
  repeated across random sizes, is the acceptance evidence.
