---
name: tcp-one-shot-connect-review
description: fix-tcp-one-shot-connect — current verdict APPROVED WITH CONDITIONS (2026-07-25, conditions cleared) on the D5/D6/D7 remediation; the earlier APPROVED was retracted same day (the "non-blocking" close/publication race was merge-blocking); plus reusable evidence techniques and a Network.framework test-timing gotcha
metadata:
  type: project
---

**CURRENT VERDICT: APPROVED WITH CONDITIONS** (fresh adversarial review, 2026-07-25, of the
remediated implementation — atomic publication claim D5 + owned close lifecycle D6/D7 + test
seams D8): no merge-blocking defect; two Low doc/bookkeeping conditions, both addressed the
same day (tasks 3.5/3.6 evidence; D5 scope sentence). The remediation was mutation-tested
with clean attribution (M1 pre-fix publication → only the two publication tests fail; M2
pre-fix close → only the two close-lifecycle tests fail). Two dependency facts verified in
NIOTS source during that review, durable for future reviews: (a) a second
`NIOTSEventLoopGroup` shutdown fails fast with `EventLoopError.shutdown` — it cannot hang
`deinit`; (b) `NIOTSConnectionBootstrap.connect` self-closes the channel on any
connect/initializer failure (`.flatMapErrorThrowing { conn.close(promise: nil); throw $0 }`)
and invokes `channelInitializer` before `register()`/connect.

**SUPERSEDED PRIOR VERDICT — do not treat the pre-remediation TCP implementation as sound.**
`fix-tcp-one-shot-connect` (branch feat/add-quic-transport) was reviewed 2026-07-25 →
APPROVED WITH CONDITIONS, upgraded to APPROVED the same day. That verdict was then
**retracted**: it had recorded the close/publication race as a *non-blocking observation*
("behavior identical to the old code"), but an adversarial review correctly graded it
merge-blocking against the strengthened `SMBTransport.close()` released-on-return-for-every-
caller contract, together with a second defect the review missed entirely:

- **Publication race**: close/cancel landing between the post-`get()` `Task.isCancelled`
  re-check and the publication lock → the success path installed a closed channel, overwrote
  terminal state with `.connected`, returned success, and repopulated `_channel` after
  `close()` had returned.
- **No owned close lifecycle**: the first `close()` set `_isClosed` before awaiting teardown;
  a concurrent caller ran an independent `shutdownGracefully()` (its "already shutting down"
  error swallowed by `try?`) and could return before the owner finished.

**Review lesson**: a race whose behavior is "identical to the old code" is NOT automatically
non-blocking — grade it against the *current* documented contract, which the same branch had
just strengthened for every conformer. The original `ConnectAttempt` reservation itself
(one-shot rejection mapping) remains verified sound and mutation-tested; the conditions below
were artifact/doc-only:
1. Moderate — the delta spec's MODIFIED requirement rewrote pre-existing prose (dropped
   "support cancellation" and the incremental-drain/bridge rationale) and added an unbacked
   "Round-trip bytes" scenario. OpenSpec MODIFIED merges intelligently and *preserves*
   unmentioned scenarios, so a delta must APPEND, never restate-and-narrow.
2. Low — `AMSMB2/SMBTransport.swift` connect doc still names only `QUICTransportApple` as
   one-shot, now misleading by omission.

**Why:** This is the same defect class fixed for QUIC in `add-quic-transport` round 9 and
recorded there as a non-blocking follow-up; closing it keeps both in-tree conformers on one
contract. Note the deliberate divergence: TCP's post-`close()` error stays `ENOTCONN`
(pre-existing contract), QUIC's is `ECONNABORTED`.

**How to apply:**
- Reviewing any OpenSpec delta spec: check the MODIFIED requirement against the *main* spec
  requirement text. Restating existing prose/scenarios in reworded form is a silent-narrowing
  risk at sync time; only new content belongs in the delta.
- Proving a test suite really guards a fix: back up the impl file (sha256 + copy to
  scratchpad), `git show HEAD:<file> > <file>`, run only the new tests, restore, verify by
  `shasum -c` and re-run green. This distinguishes real RED-first tests from tests written
  against the finished code. Used here; 3 of 4 new tests failed pre-fix, the 4th is correctly
  labeled a contract-preservation guard that passes both ways.
- **Test-timing gotcha (macOS/Network.framework):** `127.0.0.1:1` does NOT fast-refuse under
  NIOTransportServices — the connect sits in `.waiting` and burns the whole
  `connectTimeoutSeconds`, surfacing `ETIMEDOUT` (60), not `ECONNREFUSED`. Any "prompt
  rejection" elapsed-time bound in transport tests is therefore measured against the full
  connect timeout, so keep the timeout small rather than the bound large.

Related: [[quic-transport-review]], [[seam-connect-ordering]].
