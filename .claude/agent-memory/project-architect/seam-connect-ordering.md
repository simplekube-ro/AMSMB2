---
name: Seam connect-ordering fix decision
description: Root cause + architect decision for fix-seam-connect-ordering (Apple transport seam)
type: project
---

The Apple transport seam (`add-pluggable-tcp-transport`) shipped broken: every live-SMB integration
test failed because `TransportBridge.kickConnect` fired `transport.connect` in a detached
`Task { try? await … }` and the `ext.connect` C trampoline returned `0` (= "established")
immediately. libsmb2's `ext_connect` reads `0` as connected and synchronously fires NEGOTIATE into
a still-`nil` `_channel` → `POSIXError(.ENOTCONN)`, collapsing to a misleading `EPERM`
(`-(-1)=1`). Network layer was fine; pure connect/handshake ORDERING bug at the bridge↔transport
boundary.

**Why:** the seam violated libsmb2's contract that a `>=0` `ext.connect` return means the transport
can carry bytes NOW.

**How to apply (architect decision 2026-06-26, gate APPROVED):**
- **Approach A (eager connect) chosen; B rejected.** `ext_connect` runs inside the
  `eventLoopQueue.async` block, so B's `semaphore.wait()` would park the single serial queue on a
  TCP RTT — disqualifying. A `await`s `transport.connect` in the async function body BEFORE the
  continuation/eventLoopQueue block, blocking nothing; trampoline becomes a no-op returning
  `isPreConnected ? 0 : -ECONNREFUSED`.
- **Apple stays seam-only** (T9 already removed legacy Apple path); do NOT restore
  SocketMonitor/pollUntilComplete just for a T8.3 A/B compare. Re-scope "legacy vs seam identical"
  to Linux-legacy vs Apple-seam against the same Samba fixture/assertions.
- **Binding correctness mandates:** (1) keep `TransportBridge.transport` private — add
  `internal func connect(host:port:) async throws` + `isPreConnected` flag; (2) the `context==nil`
  (~Context.swift:1091) and `smb2_set_transport!=0` (~1104) early-return guards run AFTER the
  transport is connected and must explicitly close the channel (else leak), without double-releasing
  the bridge `Unmanaged`; (3) exactly-once connect; (4) preserve `ext_close` once-semantics / single
  `takeRetainedValue()`.
- The `server` string Swift parses is the IDENTICAL string libsmb2's `ext_connect` parses
  (`smb2->server`), so only parse LOGIC must match — the real endpoint is the Swift parse.
