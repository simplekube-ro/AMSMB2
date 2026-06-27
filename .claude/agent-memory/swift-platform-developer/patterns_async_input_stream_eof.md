# AsyncInputStream premature-EOF (streamed upload truncation)

Change: `openspec/changes/fix-stream-premature-eof`. Files: `AMSMB2/Stream.swift`,
`AMSMB2/AMSMB2.swift` (`write(client:from:toPath:)`), test `AMSMB2Tests/AsyncInputStreamTests.swift`.

## Root cause
`AsyncInputStream.read(_:maxLength:)` set `_streamStatus = .atEnd` on the post-copy check
`bufferOffset == buffer.count` **without** consulting producer completion. The prefetch task pauses
at `highWaterMark` (4 MiB); the consumer drains the buffered ~5 MiB and reaches buffer end before
the next chunk is appended → transient drain mis-reported as EOF → streamed upload truncates at
exactly `5242880` and `fsync`s a short file (reports success). Files < ~5 MiB escaped because the
producer finished (`iterator.next()` returned `nil`) before the consumer caught up.

## Fix (minimal, confined to Stream.swift + the one consumer)
1. `private var producerFinished = false` (read/written only under `bufferLock`). Set it in
   `prefetchData()` **after** the `while let … = try await iterator.next()` loop exits normally
   (iterator returned `nil`). A producer error leaves it `false`.
2. `read(_:maxLength:)` gates BOTH `.atEnd` transitions on `producerFinished`:
   - no-bytes branch → `0`/`.atEnd` if `producerFinished` else `-1` (would-block, status stays `.open`).
   - post-copy → `.atEnd` only when `bufferOffset == buffer.count && producerFinished`.
3. **G1**: the `catch` in `prefetchData()` MUST also `_streamError = error` under `bufferLock`
   (it was never assigned anywhere → `streamError` always `nil` → real error dropped to `EIO`).
4. Consumer `write(client:from:toPath:)` would-block contract (reads via `stream.read` directly,
   no `readData` helper — that extension was deleted as dead code):
   - `>0` → pwrite; `0` → break (EOF).
   - `-1` + `.error` → throw `streamError ?? POSIXError(.EIO)` (**G2**: discriminate on `.error`).
   - `-1` + (`.open`|`.reading`) + `streamError == nil` → would-block: `await Task.yield()`, retry (**G3**).
   - `-1` + any other status (`.closed`/`.notOpen`/`.opening`) → terminal `break` (never retry → would hang).

`Task.yield()` is outside any lock; `bufferLock` never held across `await`. `AsyncInputStream`
stays `@unchecked Sendable` (confinement to `bufferLock`).

## Gotcha: multi-pattern `case` + `where`
`case .open, .reading where cond:` binds `where` only to `.reading` (two case-items). Don't rely on
it applying to both; use an explicit `let isWouldBlock = (status == .open || status == .reading) && streamError == nil`.

## Verification (acceptance bar)
- Unit: `AsyncInputStreamTests` (4 tests) — RED first (8 failures on unfixed code), GREEN after.
- Live (Docker Samba, `SMB_TRANSPORT=seam`): FULL suite 148 tests / 0 failures; stream test x8 random
  sizes (up to ~14 MB), final `uploaded == size` every run, no `5242880` truncation.

## zsh env-passing trap (cost ~30 min this run)
The recipe's `E="…"; env $E swift test` is **bash-only**. zsh (this repo's default shell) does NOT
word-split unquoted `$E`, so the entire string becomes `SMB_SERVER`'s value → `URL(string:)` is
`nil` → EVERY integration test crashes at `TestUtilities.swift:35` "Unexpectedly found nil",
looking exactly like a code regression. Always pass vars **inline**:
`SMB_SERVER=… SMB_SHARE=… SMB_USER=… SMB_PASSWORD=… SMB_TRANSPORT=seam swift test --disable-sandbox`
(or `env ${(z)E}` to force splitting). To attribute such a crash: instrument the force-unwrap to
print the raw env value.
