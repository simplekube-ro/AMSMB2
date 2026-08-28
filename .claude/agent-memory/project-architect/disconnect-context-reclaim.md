---
name: disconnect-reclaims-context review (issue #49)
description: Reviewed change fix-disconnect-reclaims-context; verdict APPROVED WITH CONDITIONS, plus two leaks the artifacts missed
type: project
---

`openspec/changes/fix-disconnect-reclaims-context/` (GitHub issue #49) was reviewed 2026-08-28 and
recorded APPROVED WITH CONDITIONS in its proposal.md `## Review`.

**Why:** `SMB2Client.disconnect()` never destroyed the `smb2_context`, and the `cb.dataHandler`
wrappers in `async_await`/`async_await_pdu` capture `self` strongly. libsmb2's `+1` on `CBData`
therefore pins the client, making `deinit` (the only `smb2_destroy_context` caller) unreachable —
a permanent leak, not "bounded until deinit" as issue #49 states.

Two things the artifacts missed that I added to design.md:
1. `teardownSeam()` never balances the `Unmanaged<TransportBridge>` +1 in `ext.userdata`; only
   `smb2_destroy_context -> ext_close` does. So `disconnect()` strands the bridge + NIO channel too.
2. `SMB2Manager.with(shareName:)` (used by `listShares`) calls `setClient(client)` then
   `client.disconnect()` without `setClient(nil)` — the manager keeps a disconnected client.

**How to apply:** when reviewing anything that touches `disconnect()`/`shutdown()`/teardown, check
(a) fail-before-destroy ordering (it is what makes `[weak self]` in dataHandler unobservable during
`deinit` — the "self is always live in generic_handler" argument is FALSE for the deinit path,
Swift zeroes weak refs once dealloc begins), and (b) whether the C-side `ext.userdata` retain is
balanced. Two pre-existing hazards are recorded in that design.md Risks section and should not be
re-diagnosed as regressions: the `flushOutboundForSeam` error window, and libsmb2's
`smb2_destroy_context` double-fire of `smb2->pdu` reachable only via `socket.c` "compound reply
received out of order".
