# Proposal: fix-tcp-one-shot-connect

## Why

`TCPTransportApple` is public and documented as one instance per connection lifetime, but
`connect(host:port:)` never checks whether an attempt already ran: every call passes the
closed-guard and starts a fresh NIOTS bootstrap, then unconditionally stores its result into
`_channel`. Consequences (the same defect class fixed for `QUICTransportApple` in
`add-quic-transport` round 9, where this was recorded as a non-blocking observation for
follow-up):

- Two concurrent `connect` calls run two bootstraps; whichever completes last overwrites
  `_channel`, leaking or replacing the other's live channel (the loser's channel is never
  closed by the transport).
- A `connect` after a successful connect replaces the established channel the same way.
- "Unreachable via `SMB2Client`" is not a defense: the class and its initializer are public.

## What changes

- `TCPTransportApple.connect` becomes strictly **one-shot**, mirroring
  `QUICTransportApple`'s reservation: the first call atomically reserves the instance's
  single attempt under the existing `NSLock`, before any bootstrap work; every other call is
  rejected promptly without creating a bootstrap, a channel, or any network activity, and
  without touching the owning attempt's state.
- Rejection mapping: attempt in flight → `POSIXError(.EALREADY)`; after success →
  `POSIXError(.EISCONN)`; after a failed attempt → `POSIXError(.EALREADY)` (retry
  unsupported — build a fresh transport, as `SMB2Client` does); after `close()` →
  `POSIXError(.ENOTCONN, "transport is closed")` — the TCP conformer's **existing**
  closed-transport contract, preserved and checked first.
- `SMBTransport.connect`'s doc is updated to state that **both** in-tree conformers are now
  strictly one-shot, including the deliberate divergence in the post-`close()` code
  (`ECONNABORTED` on QUIC vs `ENOTCONN` on TCP — each conformer's pre-existing closed
  contract); the TCP doc comment states the full rejection contract.
- For the original one-shot contract, no injected seams are added: those deterministic tests
  use the file's established patterns (refused localhost port, TEST-NET-1 pending connect,
  and an ephemeral `NWListener` for the established case).
- **(Adversarial-review remediation, 2026-07-25)** Success publication becomes an **atomic
  claim** under the state lock: the same critical section that installs `_channel` and
  `.connected` first re-checks the terminal events, with precedence close-then-cancellation.
  If `close()` won before publication, the channel is not installed and `connect` throws
  `POSIXError(.ENOTCONN)` (the conformer's closed contract); if task cancellation won, it
  throws `POSIXError(.ECANCELED)`. No terminal close/cancellation state can be overwritten by
  `.connected`, and the losing side closes/releases the channel exactly once (ownership
  transfer: whoever takes the channel reference out of the lock-guarded state closes it).
- **(Adversarial-review remediation, 2026-07-25)** `close()` gains a first-caller-**owned**
  lifecycle `open → closing(waiters) → closed`, mirroring `QUICTransportApple`: exactly one
  caller owns channel closure, receiver unblocking, connect-tail draining, and event-loop-group
  shutdown; callers arriving during `.closing` park and are resumed only after the owner's
  fully-completed teardown; only a call after `.closed` is a terminal no-op. The owner drains
  any in-flight connect work before shutting the group down and publishing `.closed`, so once
  `close()` returns, `_channel` can never be repopulated and no connect tail can create or
  retain resources. No lock is held across an `await`, a NIO call, or a continuation
  resumption; every waiter is resumed exactly once.
- **(Adversarial-review remediation, 2026-07-25)** Minimal internal test seams are added to
  make both races deterministically provable without sleeps or TEST-NET timing: an optional
  pre-publication gate awaited immediately before the publication critical section, an
  optional close-teardown gate awaited by the owner before the group shutdown, and internal
  observability accessors (installed-channel flag, parked-close-waiter count, aborted-connect
  channel-close count). All seams are `internal`, `nil`/inert in production, and follow the
  QUIC conformer's established seam precedent (design D8).

## Capabilities

- `tcp-transport-apple` (MODIFIED: connect requirement gains the one-shot contract)

## Out of scope

- `TransportBridge.close()` fire-and-forget of `transport.close()` (separate observation).
- Any change to the QUIC conformer. (The `SMBTransport.connect` doc comment IS updated — a
  one-sentence truth fix so the protocol text no longer singles out QUIC as the only
  one-shot conformer; no protocol requirement changes.)

## Review

**VERDICT: APPROVED WITH CONDITIONS** (project-architect, 2026-07-25 — genuinely fresh
adversarial review of the complete live diff at HEAD `c99ace5` + unstaged changes; no prior
verdict, reviewer summary, or memory claim was relied upon). Both conditions are Low severity
and documentation/bookkeeping only. No merge-blocking defect was found: the reviewer
re-derived every check-then-act pair, enumerated every closer of a connect channel, hunted
deadlocks and waiter stranding, and mutation-tested the new tests in an isolated copy.

Findings (recorded verbatim from the review):

1. **(Verified sound — no defect) Atomic publication claim closes the race that superseded
   the previous verdict.** The terminal re-check and the publication are one critical
   section: `_closeState != .open` → `.closeWon`; then `_connectCancelled || Task.isCancelled`
   → `.cancellationWon`; else install. Close-before-cancel precedence is correct and
   necessary because `close()` also sets the cancel latch — latch-first would misreport a
   plain close as `ECANCELED`. Publication into a terminal state is impossible because
   `close()` claims `.closing` and takes the channel in the same critical section, so
   `_channel` can never be repopulated after `close()` returned. `Task.isCancelled` read
   inside `lock.withLock` is valid (task-local read, no suspension, no re-entrancy).
2. **(Verified sound — no defect) Exactly-once closure of a never-published channel, by
   ownership transfer.** Four closers exist and all funnel through
   `takeConnectingChannelLocked()`, which nils the slot under the lock: the
   `channelInitializer` cancel-latch path (closes a channel it never stored), `onCancel`,
   the `close()` owner, and the losing publication claim. The `.published` branch transfers
   ownership to `_channel` in the same section. The bare `defer { _connectingChannel = nil }`
   drops a reference without closing, which is correct: verified in the dependency source
   that `NIOTSConnectionBootstrap.connect` ends in `.flatMapErrorThrowing { conn.close(...);
   throw $0 }`, so a failed connect future needs no closer — design D7's claim is factually
   correct, not assumed.
3. **(Verified sound — no defect) Owned close lifecycle: no stranding, no double-resume, no
   lock across await.** Every park re-checks state under the lock before appending, so a
   caller cannot park after the state it waits on has already been published; both waiter
   arrays are drained-and-emptied under the lock with resumption strictly outside it. The
   owner cannot exit early: every teardown call is `try?`-swallowed and non-cancellable, so
   `.closed` is always published and waiters always resume exactly once. Defer ordering is
   as documented: `finishConnectWork` is declared first and therefore runs last — a resumed
   close owner provably sees a tail that can no longer create or retain resources.
4. **(Verified sound — no defect) Deadlock analysis.** The close owner awaits
   `channel.close().get()`, then the connect tail, then the group shutdown, holding no lock
   across any of them. The connect tail is prompt by construction on every path. The
   reservation and the closed-guard are one critical section, so `connectWorkInFlight` can
   never be set after `close()` claimed `.closing` — a close that parks always has a real
   tail to wait for. A rejected `connect` caller cannot clear the owner's flag because the
   `defer` is declared after the throwing guard.
5. **(Verified sound — no defect) `deinit` safety net remains correct under the new
   lifecycle.** A second `syncShutdownGracefully()` after a completed `close()` does not
   hang: `NIOTSEventLoop.closeGently()` fails promptly with `EventLoopError.shutdown` when
   the loop is already closed, and `NIOTSEventLoop.execute` still enqueues after close by
   design, so the completion callback always fires and `try?` swallows the error.
6. **(Verified sound — no defect) Contract preservation.** One-shot rejections are
   byte-identical in mapping; `receive()` post-close empty-`Data` keys off
   `_closeState != .open`, observably identical to the old `_isClosed`; the close lifecycle
   matches `SMBTransport.close()`'s documented contract verbatim. No public API surface
   changed: all five seams are `internal` and each has a call site in the test suite.
7. **(Verified — test honesty confirmed by mutation, not by inspection.)** In an isolated
   worktree copy (reviewed checkout hash-verified unchanged), mutation M1 (pre-fix
   publication) failed exactly the two publication-race tests (5 assertion failures);
   mutation M2 (pre-fix close: latch-then-teardown, no owner) failed exactly the two
   close-lifecycle-dependent tests (`entryCount 2 ≠ 1`, `3 ≠ 1`, close-returned-early).
   Attribution is clean in both directions. Assertions are on real behavior; the tests run
   in 0.013 s total with no sleeps, no TEST-NET endpoints, and bounded `waitUntil` polling
   of lock-guarded state only.
8. **CONDITION — Low (artifact bookkeeping).** tasks.md 3.5/3.6 were still unchecked though
   the verification ran and this review is the 3.6 deliverable; check them with evidence.
9. **CONDITION — Low (documentation of an unspecified error path).** The
   close-vs-cancellation precedence applies only to the post-success publication claim; a
   `close()` aborting a not-yet-succeeded connect routes through the `catch` and surfaces
   whatever `mapError` yields (typically `ENOTCONN`, but `EIO`/`ETIMEDOUT`/`ECANCELED` are
   reachable). Add one sentence to design.md D5 scoping the guarantee (documentation alone
   satisfies this condition).
10. **Observation — no action required.** `close()` may remain suspended up to the connect
    tail's natural bound (`connectTimeoutSeconds`) in a pathological abort case — the
    intended cost of the released-on-return contract; invisible to the only production
    caller (`TransportBridge.close()` fire-and-forgets).
11. **Observation — no action required.** The drain covers connect work and the suspended
    receiver but not an in-flight `send()`; safe because the owner closes and awaits the
    channel before the group shutdown, and NIO fails outstanding write promises on close.
12. **Observation.** The `:ro` mount makes a stale `Package.resolved` fail loudly in the
    container instead of silently rewriting the host checkout; `cleanlinuxtest` relies on
    the `Dependencies/libsmb2` submodule being checked out at image-build time (no
    `.dockerignore`, unfiltered COPY).
13. **Memory records** were reviewed as accurate; to be updated with this verdict and two
    verified dependency facts (second NIOTS group shutdown fails fast — cannot hang
    `deinit`; `NIOTSConnectionBootstrap.connect` self-closes the channel on any
    connect/initializer failure and runs `channelInitializer` before `register()`).

Reviewer's first-hand verification log: full read of `TCPTransportApple.swift` (686 lines)
and the complete 12-file diff (774 insertions, 61 deletions); dependency-source reads for
the three load-bearing NIO claims; TCP suite 17/0 (once plain, 3× under
`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`); full suite 278 tests / 67 skipped / 0 failures;
mutation runs M1/M2 in an isolated copy with clean attribution; `make linuxtest` run
first-hand (exit 0, 137 tests / 51 skipped / 0 failures, aarch64-unknown-linux-gnu);
`openspec validate --strict` valid for both changes with the delta confirmed append-only
against the main spec; `git diff --check` clean; no files modified by the review.

Reviewer's rationale: the remediation is architecturally correct, not merely test-passing —
both defects are eliminated at the level of the state model (atomic publication claim;
first-caller-owned close lifecycle mirroring the approved QUIC conformer), every
check-then-act pair is a single critical section, no lock is held across an await/NIO
call/resumption, and the ownership-transfer discipline makes exactly-once channel teardown
a structural property. Neither condition blocks merge; both should land before
`/opsx:archive`.

**Condition disposition (same pass, 2026-07-25):** C8 — tasks 3.5/3.6 checked with their
evidence; C9 — the D5 scope paragraph added to design.md; item 13 — both memory records
updated with the verdict and the two dependency facts.

**Reviewer confirmation (same reviewer, 2026-07-25): CONFIRMED CLEARED — the verdict stands
at APPROVED WITH CONDITIONS, both conditions cleared.** Verified first-hand:
`TCPTransportApple.swift` and `TCPTransportAppleTests.swift` byte-identical (sha256) to the
reviewed/approved state, so no re-testing was required; C8 evidence accurate (the recorded
intermediate `make linuxtest` flake is provably unrelated — the failing test's file is
untouched by this diff, which contributes zero compiled code on Linux); C9's scope paragraph
draws exactly the intended D5-versus-D6 line; memory records carry the verdict and the NIOTS
facts verbatim; both `openspec validate --strict` runs re-confirmed valid. Nothing
outstanding blocks `/opsx:verify` → `/opsx:archive`.

---

**Prior verdict history — SUPERSEDED** (2026-07-25). The APPROVED verdict below was
retracted: it explicitly classified the close/publication race ("a pre-existing close/publish
race window between the post-`get()` cancellation re-check and the channel publish") as a
non-blocking observation. A subsequent adversarial review found that classification wrong on
two counts, both merge-blocking against the strengthened `SMBTransport.close()` contract
(released-on-return for every caller):

1. **Success-publication race**: a `close()` or task cancellation landing after the
   `Task.isCancelled` re-check but before the publication lock closes the connecting channel,
   yet the success path still installs the closed channel into `_channel`, overwrites the
   terminal state with `.connected`, and returns success — so `_channel` is repopulated after
   `close()` has returned.
2. **No owned close lifecycle**: the first `close()` caller sets `_isClosed` *before* awaiting
   channel/group teardown; a concurrent caller observes `_isClosed`, starts an independent
   `shutdownGracefully()` whose "already shutting down" error is swallowed by `try?`, and can
   return before the owner's teardown completes — violating the seam promise that every
   `close()` caller returns only after the same completed teardown.

The remediation (this change, extended): atomic terminal-event-versus-success publication
with close/cancellation precedence (design D5), a first-caller-owned close lifecycle
`open → closing(waiters) → closed` with a connect-tail drain (design D6/D7), exactly-once
channel closure by ownership transfer (design D7), and deterministic race tests through
minimal internal seams (design D8). The required genuinely fresh project-architect review
ran 2026-07-25 — its verdict (APPROVED WITH CONDITIONS) is recorded above; the text below is
retained as history only.

---

**Verdict: APPROVED — SUPERSEDED, see above** (project-architect, 2026-07-25 — issued as APPROVED WITH CONDITIONS by
a fresh independent review of the proposal together with the completed live implementation,
then upgraded to APPROVED by the same reviewer after confirming both conditions cleared
first-hand against the live worktree: C1 verified byte-for-byte (the delta's requirement body
is character-identical to the main spec's prose followed by the appended one-shot paragraph,
with only the four one-shot scenarios listed), C2 verified against both conformers' actual
thrown errors, build/TCP suite/validate/diff-check re-run clean. The reviewer traced
the reservation state machine first-hand: the closed guard and reservation are one critical
section, all three `_connectAttempt` access sites are lock-guarded, exactly one caller can
take `.idle → .inFlight`, and the attempt is consumed exactly once on every exit path —
success publishes `_channel` and `.connected` atomically; the single collapsed `catch` was
verified predicate-by-predicate as behavior-preserving against the old three-branch chain
(including all three `ECANCELED` routes) and records `.failed` before every rethrow,
covering the post-`get()` cancellation re-check and close-during-connect. The
`_connectCancelled` reset removal was verified sound by enumerating every writer of the
flag. Rejected calls provably touch nothing (all three rejection arms throw before the
bootstrap literal). The reviewer ran a **mutation check** — restored the pre-fix
implementation from HEAD, ran the four new tests (3 failed exactly as the RED run claimed,
with the in-flight branch confirmed genuinely exercised on this host via the 3.005 s
pre-fix timing; the close-precedence guard passed as designed), then restored and
checksum-verified the worktree. Consumer impact confirmed nil: `SMB2Client` and
`TransportBridge` construct a fresh transport and call `connect` exactly once, so no
consumer can reach the new rejection paths. Test runs performed by the reviewer: TCP suite
14/0, full suite 275/0 with 67 server-gated skips, `openspec validate --strict` valid,
`git diff --check` clean.)

Two conditions were attached — both artifact/doc-only, no code change required — **fixed in
the same pass and confirmed cleared by the same reviewer against the live worktree**
(2026-07-25, verified first-hand as described in the verdict header; the reviewer also
re-checked this Review block itself for fidelity and found no misrepresentation):

- **C1 (moderate)**: the delta spec restated the whole "Connect, send, receive, close over a
  NIO channel" requirement instead of appending, dropping "support cancellation" and the
  bridge-coupling rationale, adding two out-of-scope normative claims ("configurable connect
  timeout", "write the full payload"), inventing an untested "Round-trip bytes" scenario,
  and narrowing the restated graceful-close scenario. *Fixed*: the delta now carries the
  original requirement prose verbatim, appends only the one-shot paragraph, and lists only
  the four new one-shot scenarios (unmentioned scenarios are preserved by MODIFIED merge
  semantics).
- **C2 (low)**: `SMBTransport.connect`'s doc still singled out `QUICTransportApple` as the
  one-shot conformer while proposal.md claimed both conformers now satisfy it and
  simultaneously declared the protocol text out of scope. *Fixed*: the doc now states both
  in-tree conformers are strictly one-shot, records the deliberate post-`close()` divergence
  (`ECONNABORTED` on QUIC vs `ENOTCONN` on TCP), and the proposal's out-of-scope section is
  reconciled.

Non-blocking observations recorded by the reviewer: a pre-existing close/publish race window
between the post-`get()` cancellation re-check and the channel publish (behavior identical to
the old code; contract holds on every path afterwards); in-flight test coverage is
environment-conditional by construction (verified genuinely exercised on this host);
`LockedBox` lives in `QUICTransportAppleTests.swift` and could move to `TestUtilities.swift`
once `add-quic-transport` lands; the `_connectCancelled` doc comment read per-attempt (a
latch note was added in the same pass); `127.0.0.1:1` surfaces `ETIMEDOUT` rather than
fast-refusing on macOS/NIOTS, so the after-failure test's 1.0 s bound has a 2× margin —
lower `connectTimeoutSeconds` rather than raising the bound if it ever flakes.
