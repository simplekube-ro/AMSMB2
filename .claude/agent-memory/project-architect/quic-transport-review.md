---
name: quic-transport-review
description: add-quic-transport gate history + first-hand verified code facts for the D7 connect state machine, port validation, and ENOTCONN contract; 7th review 2026-07-25 = APPROVED (conditions cleared)
metadata:
  type: project
---

# add-quic-transport — review gate history and verified code facts

**Current verdict: APPROVED** (seventh review, 2026-07-25 — issued as APPROVED WITH CONDITIONS,
both conditions cleared by task 6.7 and confirmed against the live worktree the same day). Fresh
independent pass over the live unstaged worktree on `feat/add-quic-transport`. All defects from
rounds 5 and 6 are
genuinely fixed and re-verified: D7 cleanup-ownership wording (design D7, proposal, ARCHITECTURE.md,
`resolveConnect` doc comment, the "No double resume" scenario), the design D4 port-range decision +
post-construction placement rationale, the phantom `claimConnectOutcome`/`ClaimedDuty` names (now
only in permitted historical text), and the ENOTCONN contract (design D3, spec requirement,
`receive()` source comment).

**The two conditions (now cleared)** were the last instances of the "winner always performs
cleanup" class, surviving one level below the requirement prose in normative *scenario* THENs:
"Deadline expiry" and "Close while connecting" both asserted the `NWConnection` "is cancelled
exactly once", false at `startPhase == .notStarted` — and the deadline one was directly falsified
by the shipped passing test `QUICTransportAppleTests.swift:497` (`cancelCount == 0`). Both now
scope the cancel to the already-started case and state pre-commit suppression explicitly.

**Why it took three rounds:** each fix round repaired the class only in the sections the review
named (requirement prose, then design/docs, then scenarios).
**How to apply:** when sweeping a phrasing class, grep normative *scenarios* as well as prose —
`cancelled exactly once`, `alone performs`, `reserved for the never-connected`, `always cancels`,
`winner's duty` — across design.md, every spec delta, docs/, and source comments.

**Why the neighbouring race scenarios needed no scoping** (checked by mechanism, not premise
reading): state events can only exist after `start()` — production installs
`stateUpdateHandler` inside `start()`, and `ScriptedQUICDriver.emit` is a silent no-op before
`start()` assigns `onState`. Independently, those scenarios never attribute the cancel to a
party, so "exactly one `cancel()`" is invariant across `.starting`/`.started` (the starting path
issues it when parked). That attribution-free phrasing is what makes a race scenario robust.

## Verified code facts (first-hand, 2026-07-25 post-remediation worktree)

- **D7 shipped contract** (`QUICTransportApple.swift`): `StartPhase{notStarted,starting,started,
  forbidden}` + `pendingLoss`. `consumeLossClaimLocked(_:error:) -> LossDuty?` (:296-314):
  `.notStarted` → forbid start, nil driver, `LossDuty(driverToCancel: nil)`; `.starting` → park in
  `pendingLoss`, return **nil**; `.started`/`.forbidden` → LossDuty carrying the driver.
  `resolveConnect(_:)` (:330-370) calls `deadline.cancel()` only *after* `guard let duty`, so a
  parked loss cancels nothing — the setup body's post-`start()` handoff (:254-264) does
  `deadline.cancel()` → `driver.cancel()` → `resume(throwing:)`. `.ready` retains the driver.
  `close()` returns `.noop` when its loss is parked (:573-579) — hence it can return before the
  start fires (design D7's "accepted cost of the parked window" paragraph is accurate).
- **Port validation**: `NWConnectionQUICDriver.init` (:698-712) builds `NWParameters` first, then
  `UInt16(exactly: port)` + `rawPort > 0`; on reject stores `connection = nil` /
  `initError = EINVAL` — no `NWConnection`. `start()` (:714-726) synchronously emits
  `.failed(initError)`, which lands in the `.starting` window → parked → post-start handoff →
  `connect` throws `EINVAL`. Traced end-to-end; design D4:192-220 describes it accurately.
  `parseLeadingPort` (pre-existing, shared with `.tcp`) traps on Int overflow for absurd digit
  strings — the only input where the documented "outside 1...65535 → EINVAL" claim doesn't hold.
- **ENOTCONN parity**: QUIC `send` (:504-512) and TCP `send` (`TCPTransportApple.swift:185-188`)
  both throw ENOTCONN when no connection exists, including post-close. `receive()` after close
  returns empty `Data` on both; `receive()` never-connected throws ENOTCONN on both. No canonical
  requirement in `openspec/specs/` constrains this and `SMBTransport`'s protocol doc is silent —
  so correcting the spec (not the code) was the right call.
- **Buffered-drain divergence is genuinely unobservable**: QUIC `receive()` drains `inboundChunks`
  before the `isClosed` check (:521-525); TCP short-circuits on `_isClosed`
  (`TCPTransportApple.swift:209-211`). `TransportBridge.close()` (:153-182) cancels the inbound
  pump task *before* firing `transport.close()`, so no consumer path can observe it — documenting
  rather than "fixing" is the correct call (a fix would either discard buffered bytes or churn TCP).

## Earlier gate history (condensed)

Rounds 1–2: eight + eight adversarial defects repaired (D5/D6/D7/D10/D11). Round 3: three defects
(ready-after-cancel ownership → D12; D7/D8 post-ready `.cancelled` → recorded-cause lifecycle;
numeric-table weakening). Round 4 (2026-07-24): APPROVED, no conditions — later superseded as
predating the 6.x adversarial-fix round. Round 5 (2026-07-25): NEEDS REVISION (three defects).
Round 6 (2026-07-25): NEEDS REVISION (two surviving instances of the same two classes).
Round 7 (2026-07-25): APPROVED WITH CONDITIONS (two scenario-level over-claims) → conditions
cleared by task 6.7 and confirmed the same day, so the standing verdict is **APPROVED**.
