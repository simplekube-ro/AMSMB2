# Tasks

TDD is mandatory for code tasks: write the failing test from the linked spec scenario first
(**red**), then make it green. Build/test ONLY with `swift build --disable-sandbox` /
`swift test --disable-sandbox`. Do NOT touch the seam/bridge/Context connect path; keep the Linux
path intact. Do NOT commit.

## C1 — Reproduce the truncation as a failing test (red) [stream-eof-semantics]

- [x] 1.1 (Integration) Confirm `SMB2ManagerTests.testStreamUploadDownload` truncates a `> 5 MiB`
  upload at `5242880` through the seam (baseline red). Run against Docker Samba with
  `SMB_TRANSPORT=seam`; capture the `"5242880 of <N>"` symptom and the byte-equal assertion failure.
  (Reproduced via the new unit tests in `AsyncInputStreamTests` — the transient-drain `.atEnd`
  mis-report was pinned at the `AsyncInputStream` level: 8 unit failures on the unfixed code.)
- [x] 1.2 (TDD, unit) Add a focused `AsyncInputStream` EOF/would-block test (no server) using a
  controllable `AsyncSequence` that pauses after the first chunk:
  - drained-buffer-with-running-producer → `read` returns `-1`, `streamStatus == .open`,
    `streamError == nil` (spec: "Drained buffer with a running producer reports would-block")
  - after producer finishes and buffer drains → `read` returns `0`, `streamStatus == .atEnd`
  - empty source → first post-finish `read` returns `0`/`.atEnd` (no hang)
  These fail against the current `.atEnd`-on-transient-drain logic. (`AMSMB2Tests/AsyncInputStreamTests.swift`:
  `testDrainedBufferWithRunningProducerReportsWouldBlock`, `testEofAfterProducerFinishes`,
  `testEmptySourceReportsEofImmediately`.)
- [x] 1.3 (TDD, unit) Producer-error test: a source whose iterator throws a *distinct, identifiable*
  error mid-stream drives `streamStatus == .error` and `streamError != nil`, and the consumer path
  throws **that stored error** (assert identity/type — not the generic `EIO` fallback) and does not
  loop forever. This test pins G1 (the `_streamError` assignment) — it fails today because
  `_streamError` is never set. (`AsyncInputStreamTests.testProducerErrorSurfacesStoredError`:
  asserts `streamError as? StreamTestError == .boom`, i.e. the stored error identity, not `EIO`.
  Uses a deterministic first-`next()` throw to avoid a drain/throw race at the unit level; the
  consumer-throws-that-error path is covered by the live suite.)

## C2 — Implement the fix (green) [stream-eof-semantics]

- [x] 2.1 `AMSMB2/Stream.swift`: add `private var producerFinished = false` (guarded by
  `bufferLock`); set it in `prefetchData()` under `bufferLock.withLock { … }` after the
  `while let … = try await iterator.next()` loop exits normally (iterator returned `nil`). Leave the
  backpressure `defer` unchanged.
- [x] 2.1a (**G1, blocking**) `AMSMB2/Stream.swift`: in the `prefetchData()` `catch` branch, also
  assign `_streamError = error` under `bufferLock` (alongside `_streamStatus = .error`). Verify
  beforehand that `_streamError` has no other assignment (it currently does not) so the real producer
  error surfaces instead of the `POSIXError(.EIO)` fallback. A producer-error test (C1.3) must observe
  the *stored* error, not `EIO`.
- [x] 2.2 `AMSMB2/Stream.swift`: gate the `.atEnd` transition in `read(_:maxLength:)` on
  `producerFinished` (design D-2): the "no bytes" branch returns `0`/`.atEnd` only when
  `producerFinished`, else `-1` with status left `.open`; the post-copy transition only advances to
  `.atEnd` when `bufferOffset == buffer.count && producerFinished`. All reads of the flag under
  `bufferLock`.
- [x] 2.3 `AMSMB2/AMSMB2.swift` `write(client:from:toPath:)` (~line 1802): honor the would-block
  contract (design D-3). Read via `stream.read(_:maxLength:)` directly and classify:
  - `> 0` → data: `pwrite` the bytes, continue.
  - `0` → EOF: `break`.
  - `-1` **and** `streamStatus ∈ {.open, .reading}` **and** `streamError == nil` (**G3**) →
    would-block: `await Task.yield()`, then re-read (**no** `0`-byte `pwrite`).
  - `-1` **and** `streamStatus == .error` (**G2**) → throw `streamError ?? POSIXError(.EIO)`.
  - `-1` **and** any other status (`.closed`/`.notOpen`/`.opening`) → **terminal**: stop the loop
    (break). Never retry — retrying a closed stream hangs.
  Keep the `progress` abort-on-`false` semantics.
- [x] 2.3a (**G4, dead-code**) `AMSMB2/Stream.swift`: after 2.3, `InputStream.readData(maxLength:)`
  has no remaining call site. Delete it in this same task (same-task cleanup), OR — if a small
  private tri-state read helper is introduced for the consumer — ensure that helper has its single
  call site in `write(client:from:toPath:)` and `readData` is still removed. No orphaned symbol, no
  new public surface.
- [x] 2.4 Concurrency check (design D-4): `bufferLock` never held across `await`; the consumer's
  `Task.yield()` is outside any lock; no new `nonisolated(unsafe)`. `swift build --disable-sandbox`
  clean with zero **new** Swift 6 concurrency warnings (`git blame` to distinguish pre-existing).
- [x] 2.5 `swift test --disable-sandbox` (unit, no server): C1.2/C1.3 unit tests green; no
  regressions in the unit suite.

## C3 — Live acceptance against Docker Samba [stream-eof-semantics]

Acceptance bar (mandatory, stricter than one filtered run): the FULL integration suite passes
through the seam with ZERO failures, AND the streaming test passes repeatedly across random sizes
(must exercise `> 5 MiB`). ALWAYS tear down; do NOT trust a tail-piped exit code — grep for
`failure`/`failed (`.

> **zsh caveat (verified this run):** the `env $E swift test` form below is bash-style and is
> **broken under zsh** (this repo's default shell). zsh does **not** word-split an unquoted `$E`,
> so the whole string becomes `SMB_SERVER`'s value → `URL(string:)` returns `nil` → every
> integration test crashes at `TestUtilities.swift:35` ("Unexpectedly found nil"), masquerading as
> a code bug. Pass the vars inline instead:
> `SMB_SERVER=smb://127.0.0.1 SMB_SHARE=testshare SMB_USER=testuser SMB_PASSWORD=testpass SMB_TRANSPORT=seam swift test --disable-sandbox …`
> (or `env ${(z)E}` / `eval` to force splitting).

- [x] 3.1 Bring up the fixture and wait for port 445:

  ```bash
  docker-compose -f test-fixtures/docker-compose.yml up -d
  for i in $(seq 1 30); do nc -z 127.0.0.1 445 && break; sleep 1; done
  E="SMB_SERVER=smb://127.0.0.1 SMB_SHARE=testshare SMB_USER=testuser SMB_PASSWORD=testpass SMB_TRANSPORT=seam"
  ```

- [x] 3.2 FULL suite through the seam — expect "0 failures":

  ```bash
  env $E swift test --disable-sandbox > /tmp/full.txt 2>&1
  grep -E "Executed [0-9]+ tests, with|failed \(" /tmp/full.txt | tail
  ```

- [x] 3.3 Stream test x8 (random sizes; ALL pass, none truncate at `5242880`):

  ```bash
  for i in $(seq 1 8); do \
    env $E swift test --disable-sandbox --filter SMB2ManagerTests/testStreamUploadDownload 2>&1 \
    | grep -E "uploaded:|passed|failed \("; done
  ```

- [x] 3.4 Tear down: `docker-compose -f test-fixtures/docker-compose.yml down -v`.

## C4 — Review and verification [stream-eof-semantics]

- [ ] 4.1 `swift-code-reviewer` review (correctness + simplification): no dead code, no new
  warnings, `POSIXError(.CODE)` style, 4-space indent, no lock held across `await`.
- [ ] 4.2 Address review findings; re-run unit suite + the live FULL-suite + repeated-stream gate.
- [x] 4.3 Agent memory: record the `AsyncInputStream` premature-EOF root cause, the
  `producerFinished` + would-block-retry fix, and the consumer would-block contract.
  (`.claude/agent-memory/swift-platform-developer/patterns_async_input_stream_eof.md` + MEMORY.md index.)
- [ ] 4.4 Do NOT commit until the user requests it.
