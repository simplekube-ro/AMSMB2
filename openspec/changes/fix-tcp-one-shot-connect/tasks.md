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
      the genuine verdict in proposal.md's `## Review` section. Recorded: APPROVED (issued as APPROVED WITH CONDITIONS, both conditions cleared and confirmed first-hand by the same reviewer).
