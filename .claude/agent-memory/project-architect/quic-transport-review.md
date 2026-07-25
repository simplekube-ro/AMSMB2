---
name: quic-transport-review
description: add-quic-transport gate history + first-hand verified code facts (D7 close-waiter teardown, layered port validation, ENOTCONN); 8th review 2026-07-25 = APPROVED (conditions cleared)
metadata:
  type: project
---

# add-quic-transport — review gate history and verified code facts

**Current verdict: APPROVED** (eighth review, 2026-07-25, over the live unstaged worktree on
`feat/add-quic-transport`; issued as APPROVED WITH CONDITIONS, all three conditions cleared the
same day and re-verified first-hand). The fourth remediation pass (tasks 7.1–7.5) is correct:
close-waiter teardown, overflow-safe port parsing, dedicated start queue. The conditions were
wording-honesty only; no code changed to clear them (`Context.swift` diff unchanged at 19 lines,
`QUICTransportApple.swift` +4 lines confined to the `close()` doc comment).

## The cleared conditions (kept — this is the recurring failure mode)

1. The **absolute** `close()`-barrier claim was narrowly false on the `.ready`-wins-during-the-
   commit-to-start-window path: `.ready` resolves the claim (no loss parked ⇒ `teardownPending`
   stays false), so `close()` takes the established-teardown branch, cancels the driver itself,
   and returns while `driver.start()` may still be executing on `startQueue` (the real driver is
   between `connection.start(queue:)` and `armReceive()`). Harmless (the trailing
   `connection.receive` hits a cancelled connection whose `onReceive`/`stateUpdateHandler` were
   cleared by `cancel()`). Cleared by scoping every claim to "a committed start whose **loss was
   parked**", in six places: the `close()` doc comment, the gap test's doc comment, design D7
   ("Consequences" + a new "The promise is scoped precisely" paragraph that also absorbs the
   armed-deadline-timer tail), both `quic-transport-apple` spec sites, `docs/ARCHITECTURE.md`,
   and the proposal summary sentence.
2. `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` is **not** a width-1 knob — it disables cooperative-
   pool overcommit. The real guarantee is structural (start runs on a GCD queue; the connect task
   is suspended on its continuation). Design D7 now states the structural proof and demotes the
   strict-pool run to corroborating evidence.
3. Pass-number drift between the superseded banner and tasks.md §7.

**Why it matters:** this change has been gated four times for over-claiming class defects
(winner-always-cancels, then scenario-level repeats, then this). Absolute invariants are the
recurring trap.
**How to apply:** whenever a fix strengthens a documented invariant from "accepted cost" to
"never", re-derive the invariant against *every* claim path — here the `.ready` path, which owns
no parked loss and therefore bypasses the new waiter machinery entirely. And prefer
"released-on-return means no pending teardown and no cancellable resource left" over
"nothing executes afterward" — the latter is almost never true of an async teardown.

## Verified code facts (first-hand, 2026-07-25, fourth-pass worktree)

- **D7 close-waiter mechanism is sound.** `consumeLossClaimLocked` `.starting` branch parks
  `pendingLoss` **and** sets `teardownPending` in the same critical section that sets
  `isClosed`; the post-start handoff on `startQueue` does lockA(`startPhase=.started`, take
  `pendingLoss`) → `deadline.cancel()`/`driver.cancel()`/resume → lockB(`teardownPending=false`,
  drain `closeWaiters`) → resume waiters. Every close/park decision and the drain are the same
  lock, so a close arriving between lockA and lockB parks and is drained; one arriving after
  lockB reads false. Only one loss can ever be claimed (`connectState=.failed` gates the rest),
  so no second park, no double cancel, no waiter leak. `startQueue.async` is unconditionally
  reached once `.starting` commits. The captured `driver` is the *local* one, not the nil'd
  `self.driver` — correct object for both start and cancel.
- **`parseLeadingPort` overflow fix**: accumulation stops once `port > 65535`; intermediate
  bounded at 655,359. In-range ports parse byte-identically to the old code. TCP downstream is
  safe: `NIOTSConnectionBootstrap.connect(host:port:)` range-checks and returns
  `NIOTSErrors.InvalidPort` — it does not trap (previously the parser itself trapped).
- **Layered port validation**: `Context.swift:1299` `(1...65535).contains(endpoint.port)` before
  transport construction; `NWConnectionQUICDriver.init` keeps `UInt16(exactly:)` + `> 0` for
  directly constructed transports. Boundaries 1 and 65535 accepted at both layers.
- **Known benign residuals** (non-blocking, mostly pre-existing): a close/cancel winning between
  the continuation store (`:231`) and `deadline.schedule` (`:245`) leaves an armed
  `DispatchSourceTimer` alive for up to `connectTimeout` past `close()` (weak self, bounded);
  dead `if lifecycle == .active` at `:619-622`; `receive()` resumes its own continuation while
  holding the lock (`:549-571`) — safe, the body never suspends.
- **ENOTCONN parity / buffered-drain divergence**: unchanged from the seventh review and still
  accurate.

## Earlier gate history (condensed)

Rounds 1–2: eight + eight adversarial defects (D5/D6/D7/D10/D11). Round 3: three defects
(ready-after-cancel ownership → D12; post-ready `.cancelled` → recorded-cause lifecycle; numeric
table). Round 4 (2026-07-24): APPROVED, superseded. Round 5: NEEDS REVISION (three). Round 6:
NEEDS REVISION (two surviving instances of the same classes). Round 7: APPROVED WITH CONDITIONS
→ cleared by task 6.7. Round 8 (2026-07-25): APPROVED WITH CONDITIONS (three wording items above)
after the fourth remediation pass fixed the two findings round 7 had recorded as accepted costs.
