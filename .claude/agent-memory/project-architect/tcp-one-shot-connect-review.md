---
name: tcp-one-shot-connect-review
description: fix-tcp-one-shot-connect review outcome (APPROVED WITH CONDITIONS 2026-07-25) + reusable evidence techniques and a Network.framework test-timing gotcha
metadata:
  type: project
---

`fix-tcp-one-shot-connect` (branch feat/add-quic-transport, unstaged worktree) reviewed
2026-07-25 → APPROVED WITH CONDITIONS, then **upgraded to APPROVED** the same day after
first-hand verification that both conditions were cleared. Implementation
(`AMSMB2/TCPTransportApple.swift` `ConnectAttempt` reservation) verified sound and
mutation-tested; both conditions were artifact/doc-only:
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
