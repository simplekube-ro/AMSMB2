# Tasks: fix-tcp-one-shot-connect

## 1. Implementation (TDD)

- [x] 1.1 RED — add failing tests to `AMSMB2Tests/TCPTransportAppleTests.swift`: in-flight
      second connect → prompt `EALREADY` (TEST-NET-1 pending-connect pattern; also valid on
      fast-fail hosts, where the attempt is already `.failed`); connect after established →
      `EISCONN` with the original channel still usable for `send` (ephemeral `NWListener`);
      connect after a failed attempt → prompt `EALREADY` (refused-port pattern, elapsed-time
      bound proves no second bootstrap); connect after close → existing `ENOTCONN` precedence
      guard. All waits bounded; run and observe the expected failures.
- [x] 1.2 GREEN — add the `ConnectAttempt` reservation state machine to
      `AMSMB2/TCPTransportApple.swift` (design D1/D2): reservation + closed-guard in one
      critical section before any bootstrap; success publishes `_channel` and `.connected`
      atomically; a single `catch` records `.failed` then applies the unchanged error
      mapping; the unreachable `_connectCancelled` reset removed (D3); doc comment states the
      one-shot contract.
- [x] 1.3 Verify: TCP suite, QUIC suite (unchanged), full suite
      (`swift test --disable-sandbox`), `openspec validate fix-tcp-one-shot-connect
      --strict`, `git diff --check`.

## 2. Review

- [x] 2.1 Fresh project-architect review of the proposal and the live implementation; record
      the genuine verdict in proposal.md's `## Review` section. Recorded: APPROVED (issued as APPROVED WITH CONDITIONS, both conditions cleared and confirmed first-hand by the same reviewer). **SUPERSEDED 2026-07-25** — that verdict wrongly classified the close/publication race as non-blocking; see section 3.

## 3. Adversarial-review remediation (publication race + owned close lifecycle)

- [x] 3.1 Artifacts first: mark the section-2 approval superseded/pending in proposal.md,
      specify the atomic publication claim (D5), the owned close lifecycle (D6), the
      connect-tail drain and exactly-once closure (D7), and the test seams (D8) in
      design.md and the delta spec; update the add-quic-transport artifacts that claimed the
      shared `close()` guarantee held or that `make linuxtest` was green; correct both
      project-architect memory records.
- [x] 3.2 RED — deterministic tests in `AMSMB2Tests/TCPTransportAppleTests.swift` gated on
      the D8 seams (no sleeps/TEST-NET/wall-clock proofs): close-wins-pre-publication
      (connect must not return success, channel not installed, close waits for the connect
      tail), cancellation-wins-pre-publication (`ECANCELED`, no channel installed, teardown
      exactly once), two concurrent closes parked while the owner's teardown is gated
      (single teardown entry, both resumed on release), close-after-completed-close terminal
      no-op (no second teardown entry). Watch each fail against the current implementation.
- [x] 3.3 GREEN — implement D5–D8 in `AMSMB2/TCPTransportApple.swift` as one coherent state
      model (`ConnectAttempt` + `CloseState` + connect-work drain), replacing `_isClosed`;
      all new and existing TCP tests green.
- [x] 3.4 Repair the Linux verification targets: `make linuxtest` mounts a quoted
      `$(CURDIR)` read-only and builds in a container scratch path; the clean image carries
      `Dependencies/libsmb2`; run the exact repaired `make linuxtest` and
      `make cleanlinuxtest`.
- [x] 3.5 Verify: focused new tests, full `TCPTransportAppleTests`, `QUICTransportAppleTests`
      (plain and `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), full
      `swift test --disable-sandbox`, `openspec validate` (both changes, `--strict`),
      `git diff --check`. Evidence (2026-07-25): focused 3/0; TCP suite 17/0; QUIC suite
      41/0 plain and 41/0 strict-pool; full suite 278 tests / 67 skipped / 0 failures; both
      validates valid; diff-check clean; `make linuxtest` exit 0 and `make cleanlinuxtest`
      exit 0 (each 137 tests / 51 skipped / 0 failures on aarch64-unknown-linux-gnu; one
      intermediate `linuxtest` run hit the pre-existing flaky
      `AsyncInputStreamTests.testStatusSnapshotReturnsStoredErrorOnErrorPath` — unrelated to
      this diff, passed on immediate re-run in 0.001 s).
- [x] 3.6 Genuinely fresh project-architect review of the complete live diff; record the
      actual verdict in proposal.md (do not restore APPROVED unless it is the real outcome).
      Recorded: APPROVED WITH CONDITIONS (two Low, documentation/bookkeeping-only conditions,
      both addressed in the same pass; verdict recorded verbatim in proposal.md).
