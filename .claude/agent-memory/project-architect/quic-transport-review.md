---
name: quic-transport-review
description: add-quic-transport gate history + first-hand verified code facts; 9th review 2026-07-25 = APPROVED (sole should-fix condition cleared) after the state-machine ownership repair
metadata:
  type: project
---

# add-quic-transport — review gate history and verified code facts

**Current verdict: APPROVED** (ninth review, 2026-07-25, live unstaged worktree on
`feat/add-quic-transport`, HEAD `a2f8078` + unstaged; issued as APPROVED WITH CONDITIONS with a
single should-fix — `SMBTransport.connect`'s "Conformers document…" over-claimed for
`TCPTransportApple` — cleared the same day by softening to "Conformers **should** document…" and
re-verified first-hand: source diffstat unchanged, build clean, QUIC suite 41/0). The fifth
remediation pass (tasks 8.1–8.6) fixed all four defects the round-8 APPROVED verdict had waived —
that verdict is correctly marked SUPERSEDED in proposal.md.

## What the fifth pass changed (all verified first-hand, all correct)

1. **One-shot connect reservation** — `connectState .idle → .reserved` under `lock` **before**
   trust resolution / driver construction; rejections `EALREADY`(reserved/connecting/failed) /
   `EISCONN`(ready) / `ECONNABORTED`(close, checked first). Retry after failure unsupported.
2. **Close lifecycle `open → closing → closed`** — first caller owns teardown on
   `teardownQueue`, then waits on `connectWorkInFlight`, then publishes `.closed` and drains
   `closeWaiters`. Replaces the old `isClosed`/`teardownPending` pair. Only a post-`.closed`
   call is a prompt no-op.
3. **Late-armed deadline** — post-`schedule` claim re-check (`guard mayStart` else
   `deadline.cancel(); finishConnectWork()`). Covers both the synchronous-self-fire and the
   gated-arming shapes. The "benign bounded self-expiry" scoping is retracted.
4. **`connectWorkInFlight`** spans store → arming → commit → `start()` → handoff; cleared only
   by `finishConnectWork()`. Covers ready-mid-start (close cancels the ready driver at once but
   still waits for the tail). The "ready-mid-start needs no wait" scoping is retracted.

## Structural invariants that make it correct (re-derive these if the code moves)

- Every check-then-act pair is one critical section: the store's `guard closeState == .open`
  makes it impossible for `connectWorkInFlight` to be set after close reached `.closing`; the
  waiter parks re-check `closeState == .closing` / `connectWorkInFlight` under the lock, so no
  waiter can be stranded after the owner took its snapshot.
- Exactly one path claims `.connecting`; `consumeLossClaimLocked` assigns the teardown duty
  (`.notStarted`→forbid, `.starting`→park for the handoff, `.started`→self-serve), so each
  driver is cancelled at most once and each continuation resumed exactly once.
- No injected collaborator (`driverFactory`, `driver.start/cancel/send`, `deadline.*`) and no
  continuation resume happens under the lock — except `receive()`'s own immediate resume, which
  is the safe "resume before suspending" idiom.
- No lock is held across any gated park in the test doubles ⇒ no cooperative-pool deadlock;
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` green is corroborating, not the proof.

## Known benign residuals (non-blocking, mostly pre-existing)

- `TransportBridge.close()` fire-and-forgets `transport.close()`, so the strengthened
  released-on-return promise is not propagated to libsmb2's close trampoline.
- `NWConnectionQUICDriver.armReceive` re-arms even when `onReceive` is nil (bounded: a cancelled
  NWConnection completes with error/isComplete).
- `receiveWaiter` is overwritten if two `receive()` calls park concurrently (bridge is
  single-consumer).
- `TCPTransportApple.connect` has the same latent repeated-connect overwrite the QUIC pass just
  fixed; out of scope for this change.

## Earlier gate history (condensed)

Rounds 1–2: eight + eight adversarial defects (D5/D6/D7/D10/D11). Round 3: three (ready-after-
cancel → D12; post-ready `.cancelled` → recorded-cause lifecycle). Round 4: APPROVED, superseded.
Round 5: NEEDS REVISION (three). Round 6: NEEDS REVISION (two repeats). Round 7: APPROVED WITH
CONDITIONS → cleared by 6.7. Round 8: APPROVED, later SUPERSEDED for waiving the four defects
above. **Recurring failure mode: absolute invariants asserted without re-deriving them against
every claim path, and public-API defects narrowed away as "unreachable via `SMB2Client`".**
