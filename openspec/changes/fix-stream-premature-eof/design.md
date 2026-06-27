## Context

`AsyncInputStream<Seq>` (`AMSMB2/Stream.swift`) adapts an `AsyncSequence` of `DataProtocol`
chunks into a Foundation `InputStream` so the existing synchronous `read(_:maxLength:)`-based
upload loop can drive an async source. Its moving parts:

- A background **prefetch task** (`prefetchData()`) pulls chunks via `iterator.next()` and appends
  them to an in-memory `buffer: Data?`, pausing at `highWaterMark` (4 MiB) and resuming below
  `lowWaterMark` (1 MiB) via a `backpressureContinuation`. All buffer mutation happens under
  `bufferLock` (an `NSLock`), and the lock is **never** held across an `await`.
- A synchronous **consumer** (`read(_:maxLength:)`) copies from `buffer` at `bufferOffset`,
  advances the offset, and returns the byte count.
- The single real consumer is `SMB2Manager.write(client:from:toPath:)`
  (`AMSMB2/AMSMB2.swift:1802`): inside `stream.withOpenStream { while true { let segment = try
  stream.readData(maxLength: chunkSize); if segment.isEmpty { break }; … pwrite … } }`. The
  `InputStream.readData(maxLength:)` extension (`Stream.swift:41`) calls `read(_:maxLength:)`,
  throws on a `< 0` result, and returns `Data(prefix(result))` otherwise — so today a `0` return
  yields an empty `Data`, which the loop treats as clean EOF (`break`).

### The bug, precisely

```swift
// read(_:maxLength:) today
if bufferOffset == self.buffer!.count {
    _streamStatus = .atEnd          // <-- fires on *transient* drain, not real EOF
}
```

`prefetchData()` pauses at `highWaterMark`; the consumer drains the buffered ~5 MiB and reaches
`bufferOffset == buffer.count` **before** the prefetch task has appended the next chunk. `read()`
flips `_streamStatus = .atEnd`; the next `read()` hits the `.atEnd` switch arm and returns `0`;
`readData` returns empty `Data`; the write loop `break`s. The upload truncates at exactly
`5242880` bytes and `fsync()`s a short file — reporting success.

Files `< ~5 MiB` escape because the producer's `iterator.next()` returns `nil` (loop done) before
the consumer drains, so by the time `.atEnd` is set the buffer genuinely is the whole payload.

The contract `read()` must honor: **`0`/`.atEnd` means "the producer is exhausted AND the buffer is
fully consumed"; a momentary "no bytes right now, producer still running" is *would-block*, not
EOF.**

## Goals / Non-Goals

**Goals**
- `read(_:maxLength:)` reports EOF (`0` / `.atEnd`) only after the producer's iterator has returned
  `nil` and every buffered byte has been consumed.
- A transient buffer drain reports would-block (`-1`, status stays `.open`), and the consumer
  retries until bytes arrive or the producer finishes — so all `N` bytes transfer for any `N`.
- A producer error still surfaces as a thrown `POSIXError`/`streamError`.
- No lock held across `await`; no new `nonisolated(unsafe)`; Swift 6 strict-concurrency clean.

**Non-Goals**
- No seam/transport change; no public API change; no backpressure-tuning change; no new error type
  (keep `POSIXError(.CODE)`).

## Decisions

### D-1 — `producerFinished` flag set only on natural iterator exhaustion

Add `private var producerFinished = false`, guarded by `bufferLock`. In `prefetchData()`, the
`while let data = try await iterator.next()` loop exits normally **iff** `iterator.next()` returned
`nil` (the producer is done). Set the flag there, under the lock:

```swift
while let data = try await iterator.next() {
    bufferLock.withLock { /* append to buffer (unchanged) */ }
    // … backpressure pause (unchanged) …
}
// loop fell through → iterator returned nil → producer exhausted
bufferLock.withLock { self.producerFinished = true }
```

The `catch` branch keeps `_streamStatus = .error` — an error is **not** a clean finish, so
`producerFinished` stays `false` and the consumer takes the error path, not the EOF path. The
existing `defer` that resumes a suspended `backpressureContinuation` is unchanged.

**REQUIRED (architect gate G1) — the `catch` branch MUST also assign `_streamError = error`**
(under `bufferLock`, next to `_streamStatus = .error`). Today `_streamError` is **never** assigned
anywhere in `Stream.swift` (verified: the only references are its declaration and the `streamError`
getter), so `streamError` is *always* `nil` and the real producer error is silently dropped —
`readData` currently falls back to `POSIXError(.EIO)`. The error path of *this* fix depends on the
real error surfacing, so the catch must store it:

```swift
} catch {
    bufferLock.withLock {
        _streamError = error
        _streamStatus = .error
    }
}
```

The flag is set under `bufferLock` (not merely in the `defer`) so that the read side observes it
atomically with the final buffer contents.

### D-2 — `read(_:maxLength:)` gates `.atEnd` on `producerFinished`

Two edits, both under `bufferLock`:

1. The "no bytes available" branch becomes producer-aware. When the buffer is `nil` or fully
   consumed:
   - if `producerFinished` → set `_streamStatus = .atEnd` and return `0` (true EOF), else
   - return `-1` (would-block) with the status left `.open`.

   ```swift
   if self.buffer == nil || bufferOffset >= self.buffer!.count {
       let finished = producerFinished
       if finished { _streamStatus = .atEnd }
       bufferLock.unlock()
       return finished ? 0 : -1
   }
   ```

2. The post-copy transition only advances to `.atEnd` when the producer is also done:

   ```swift
   if bufferOffset == self.buffer!.count && producerFinished {
       _streamStatus = .atEnd
   }
   ```

   When the buffer is drained but `!producerFinished`, the status stays `.open`; the *next* `read()`
   hits branch (1) and returns `-1` until the prefetch task appends more (or finishes).

The leading `switch streamStatus` is unchanged: `.atEnd → 0`, `.error/.closed/.notOpen → -1`,
`.open/.reading → fall through`. The error path is therefore: producer throws → `_streamStatus =
.error` → `read()` returns `-1` → the consumer inspects `streamError` (non-nil) and throws.

### D-3 — Would-block contract with the consumer (`write(client:from:toPath:)`)

This is the load-bearing half: `read()` now legitimately returns `-1` for would-block, but the
existing `InputStream.readData(maxLength:)` helper treats **any** `< 0` as a hard error
(`throw streamError ?? POSIXError(.EIO)`). Left unchanged, the consumer would throw `EIO` the
instant it out-paces the prefetcher. The consumer must distinguish:

| `read()` result | `streamStatus` / `streamError`             | Meaning      | Consumer action                          |
|-----------------|--------------------------------------------|--------------|------------------------------------------|
| `> 0`           | `.open`/`.reading`/`.atEnd`                | data         | `pwrite` the bytes, continue              |
| `0`             | `.atEnd`                                   | EOF          | `break` (producer exhausted)              |
| `-1`            | `.open`/`.reading`, `streamError == nil`   | would-block  | `await Task.yield()`, **retry**           |
| `-1`            | `.error` (`streamError` set)               | real error   | `throw streamError ?? POSIXError(.EIO)`   |
| `-1`            | `.closed`/`.notOpen`/`.opening`            | terminal     | stop (see G3) — **never retry**           |

**REQUIRED (architect gate G2) — discriminate the error case on `streamStatus == .error`**, not on
`streamError != nil`. `_streamStatus = .error` is reliably set under `bufferLock` by the producer;
`_streamError` is set alongside it (G1). Throw `streamError ?? POSIXError(.EIO)` so a genuine error
always terminates even if the error object were somehow absent.

**REQUIRED (architect gate G3) — classify would-block narrowly.** A `-1` is would-block **only**
when `streamStatus` is `.open` or `.reading` *and* `streamError == nil`. Any other `-1`
(`.closed`, `.notOpen`, `.opening`) is **terminal** and MUST stop the loop (break) — it MUST NOT be
retried. Retrying on `.closed` would spin forever, because a closed stream never produces bytes and
never transitions to `.atEnd` (the switch returns `-1` for `.closed`). The spec prose "`-1` whose
`streamStatus` is not `.error`" is too broad and is tightened to this `.open`/`.reading`-only set.
During a normal `withOpenStream` upload `.closed` cannot occur mid-loop (the `defer` closes only
after the handler returns); the terminal branch is a defensive guard against a hang, not an expected
path.

**Confinement note (architect gate G5).** The private `write(client:from:toPath:)` consumer only
ever receives an `AsyncInputStream` (the sole construction site is `AMSMB2.swift:1210`; there is no
public `write(stream: InputStream, …)` overload that forwards a raw Foundation `InputStream` here).
So the would-block semantics the consumer must honor are exactly `AsyncInputStream`'s — there is no
arbitrary-`InputStream` path to reason about, which shrinks the contract's risk surface.

Chosen shape: keep the synchronous `readData(maxLength:)` for the non-blocking case, but move the
EOF/would-block/error discrimination into the **async** consumer loop in
`write(client:from:toPath:)`, because only the async context can `await Task.yield()` to let the
prefetch task make progress. Concretely the loop reads via a small helper that returns an enum-like
result (data / endOfStream / wouldBlock) derived from the `read()` return + `streamStatus` +
`streamError`; on `wouldBlock` it does `await Task.yield()` and re-reads; on `endOfStream` it
breaks; data is `pwrite`-n as today. `Task.yield()` (not a sleep) is correct because the prefetch
task runs on the cooperative pool and only needs the consumer to relinquish; a `0`-byte `pwrite`
must never be issued (the `segment.isEmpty` guard stays). The retry is naturally cancellation-aware
because the enclosing `write` is `async` and the task's cancellation is observed at the next suspension.

**Why not make `read()` block until data arrives?** `read(_:maxLength:)` is a synchronous
`InputStream` override and cannot `await`; spinning it would burn a thread and risk starving the
cooperative pool the prefetch task lives on. Would-block + async-retry keeps all waiting in
structured-concurrency suspension.

### D-4 — Locking and Swift 6 concurrency

- `producerFinished` is read and written **only** under `bufferLock`, alongside `buffer` /
  `bufferOffset` / `_streamStatus`, so reads see a consistent snapshot.
- `bufferLock` is never held across an `await` (unchanged invariant): the prefetch task sets the
  flag in a `bufferLock.withLock { … }` after the `await`-driven loop, and the read side
  reads it inside the existing `lock()/unlock()` span before returning.
- The consumer's `await Task.yield()` happens **outside** any lock (the lock lives entirely inside
  `read()`), so no lock crosses a suspension point.
- `AsyncInputStream` remains `@unchecked Sendable` justified by `bufferLock` confinement; no new
  shared mutable state escapes the lock.

## Risks

- **Busy-spin under a slow producer.** If the producer is slow, the consumer could `Task.yield()`
  in a tight loop. Mitigation: `yield()` (not a spin) cooperatively reschedules so the prefetch
  task runs; the prefetch task makes forward progress on every chunk. (A bounded backoff is a
  possible refinement but is not required for correctness and would add latency to the common case.)
- **Hang if `producerFinished` is never set.** The flag must be set on *every* normal loop exit,
  including the zero-chunk source (empty stream: `iterator.next()` returns `nil` immediately →
  flag set → first `read()` returns `0`). Covered by a unit test for the empty-stream case.
- **Error masked as would-block.** If a producer throw set `.error` but the consumer only checked
  the `read()` sign, it would retry forever. Mitigation: the consumer checks `streamError`/`.error`
  on every `-1` and throws — pinned by a unit test that makes the producer throw mid-stream.
- **Regression on small files.** Files `< 5 MiB` already pass; the new gate must not break them
  (producer finishes, flag set, EOF reported normally). Covered by keeping the existing assertion
  and exercising random sizes spanning below and above the prefetch window.

## Architect Review Gate — VERDICT: APPROVED (approach=revised)

The root cause is correct and was independently re-verified against the code: `read(_:maxLength:)`
sets `_streamStatus = .atEnd` on the *post-copy* transition `bufferOffset == buffer.count` regardless
of whether the producer's iterator has returned `nil`, so a transient drain is mis-reported as EOF.
The chosen fix — a `producerFinished` flag set only on natural iterator exhaustion, gating the
`.atEnd` transition, with a `-1` would-block return that the async consumer retries via
`await Task.yield()` — is the right, minimally-invasive approach. It preserves the `InputStream`
abstraction, holds no lock across `await`, and is confined to `Stream.swift` + the single consumer.

**Approval is conditioned on the guardrails G1–G6** (folded into D-1, D-3, and the tasks):

1. **G1 — set `_streamError` in the producer `catch`.** Without it the documented error path cannot
   work; `streamError` is currently always `nil`. (Blocking.)
2. **G2 — discriminate the error case on `streamStatus == .error`**, throwing
   `streamError ?? POSIXError(.EIO)`.
3. **G3 — would-block is `.open`/`.reading` + `streamError == nil` only**; `.closed`/`.notOpen`/
   `.opening` are terminal (break), never retried, to prevent a hang.
4. **G4 — `readData(maxLength:)` dead-code decision** (see below).
5. **G5 — confinement**: consumer only ever sees an `AsyncInputStream`; no raw-`InputStream` path.
6. **G6 — liveness**: `Task.yield()` is sufficient (rationale + rejected alternative below).

### D-5 (G4) — `readData(maxLength:)` must not be left orphaned

`InputStream.readData(maxLength:)` (`Stream.swift:41`) has **exactly one** call site — the consumer
being rewritten (`AMSMB2.swift:1818`). It collapses both `0` (EOF) and `-1` (error *or* now
would-block) and cannot express the tri-state the fix needs. Decision: the consumer reads via
`stream.read(_:maxLength:)` directly (or a single small private tri-state helper with one call site)
and classifies the result per the D-3 table. If that orphans `readData(maxLength:)`, **delete it in
the same task** (CLAUDE.md same-task-cleanup / dead-code rule) — do not leave it dead. If a new
helper is introduced it must live next to the consumer and have its one call site there; no new
public surface.

### D-6 (G6) — why `Task.yield()` is sufficient; the continuation alternative is rejected

The underlying `AsyncThrowingStream(url:)` buffers the file synchronously, and `prefetchData()`
resumes the paused producer from inside `read()`'s copy path once `remaining < lowWaterMark` (1 MiB)
— i.e. *before* the buffer fully drains. The would-block window is therefore narrow, and the
consumer's dominant suspension is the per-segment `await file.pwrite`, so no pathological busy-spin
occurs in practice. A bounded backoff is an optional refinement, not required for correctness.

**Rejected alternative — block `read()` synchronously until data arrives** (semaphore/condition):
sync-over-async; burns a thread and risks starving the cooperative pool the producer lives on.

**Rejected alternative — a symmetric `dataAvailableContinuation`** (consumer suspends, producer
resumes it on append; no spin at all): genuinely cleaner on liveness, but adds a *second* checked
continuation with its own teardown obligations on close/finish/error (mirroring the existing
backpressure machinery), enlarging a release-blocking confined bugfix. Deferred as a future
refinement; the `Task.yield()` approach is accepted for this change.

**Rejected alternative — bypass `InputStream` and iterate the `AsyncSequence` directly** in the
consumer: smaller state machine, but a larger refactor touching the write path's abstraction and is
unnecessary given the confined fix. Rejected on scope/risk.

### Non-blocking observation (not required for approval)

The upload loop performs no `Task.checkCancellation()`. Adding `await Task.yield()` introduces a
suspension point but `yield()` does not throw, so a cancelled task still won't unwind here — this is
a *pre-existing* gap, out of scope. Optional cheap improvement: a `try Task.checkCancellation()` at
the top of the loop now that the loop suspends. Leave the existing `progress` abort-on-`false`
semantics intact.
