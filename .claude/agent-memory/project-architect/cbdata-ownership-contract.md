---
name: CBData retain/release ownership contract
description: The exactly-once balance rule for the per-op CBData passRetained handed to libsmb2, and how libsmb2 teardown guarantees it
type: project
---

The per-operation `CBData` (Context.swift) is handed to libsmb2 via
`Unmanaged.passRetained(cb).toOpaque()` as the opaque `cb_data`. That +1 MUST be
balanced exactly once, and only by `generic_handler`'s `takeRetainedValue()`.

**Why exactly-once holds:** libsmb2 guarantees it fires every queued PDU's callback
exactly once — on the network reply, or during `smb2_destroy_context`
(Dependencies/libsmb2/lib/init.c:313-383), which walks outqueue/pdu/waitqueue and
fires `pdu->cb(smb2, SMB2_STATUS_SHUTDOWN, ...)` before freeing. `smb2_close_context`
(libsmb2.c:171) does NOT touch the queues, so queued PDUs always survive to deinit.

**How to apply (the rule):** after a PDU is queued (any `smb2_*_async` returning success
/ `smb2_queue_pdu`), NEVER call `Unmanaged<CBData>.fromOpaque(cbPtr).release()`.
Cancellation/timeout/teardown paths (`onCancel`, timeout timer,
`failAllPendingOperations`) abandon WITHOUT releasing — same principle as read buffers
(`bufferPool.abandon`). The caller balances the retain itself ONLY on pre-queue failures:
context==nil, the async/queue/connect call threw or returned <0, `smb2_set_transport`
failed. In those cases libsmb2 never received `cbPtr`.

**Connect path is subtler (Apple seam, connectWithBridge):** `smb2_connect_share_async`
stores our `generic_handler`/cbPtr in `connect_data->cb` (not directly as a PDU cb) and
queues NEGOTIATE with internal `negotiate_cb`. At `smb2_destroy_context`, the pending
sub-step PDU (negotiate/session_setup/tree_connect) fires its internal cb with SHUTDOWN,
which propagates to `c_data->cb` (= our generic_handler) then `free_c_data` (nulls
`smb2->connect_data` to prevent the init.c:377 double-free). `ext_connect`
(transport-external.c) nulls `smb2->connect_cb` after firing it synchronously, so the
init.c:354 connect_cb branch does NOT double-fire. Net: the connect retain is also
balanced exactly once at destroy. So `connectWithBridge`'s abandoned branch should
`teardownSeam()` but NOT release and NOT destroy.

**The bug class fixed in `fix-cbdata-cancel-race-uaf`:** three post-queue abandoned
branches (async_await ~943, async_await_pdu ~1043, connectWithBridge ~1308) released the
retain even though the PDU was already queued → double-balance → UAF when the slow reply
arrives on a live context (crash seen in swift_retain on the eventloop queue).

**Latent trap to watch:** the `catch` releases in async_await (~966) and async_await_pdu
(~1065) are correct ONLY because nothing throws after the queue call inside their `do`
blocks. Adding a throwing call after `smb2_queue_pdu`/`smb2_*_async` success would turn
those catches into double-frees. Same rule applies to any future post-queue code.

**Bounded-leak (not crash) residual:** `disconnect()` calls `failAllPendingOperations`
but does NOT destroy the context, so pending PDUs + their CBData retains + abandoned read
buffers leak until `deinit` runs `smb2_destroy_context`. Safe (no UAF) but argues for
preferring a fresh client over disconnect()+pool-reuse for long-lived recycled clients.
