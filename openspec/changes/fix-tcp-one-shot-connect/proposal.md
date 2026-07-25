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
- No injected seams are added: the deterministic tests use the file's established patterns
  (refused localhost port, TEST-NET-1 pending connect, and an ephemeral `NWListener` for the
  established case).

## Capabilities

- `tcp-transport-apple` (MODIFIED: connect requirement gains the one-shot contract)

## Out of scope

- `TransportBridge.close()` fire-and-forget of `transport.close()` (separate observation).
- Any change to the QUIC conformer. (The `SMBTransport.connect` doc comment IS updated — a
  one-sentence truth fix so the protocol text no longer singles out QUIC as the only
  one-shot conformer; no protocol requirement changes.)

## Review

**Verdict: APPROVED** (project-architect, 2026-07-25 — issued as APPROVED WITH CONDITIONS by
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
