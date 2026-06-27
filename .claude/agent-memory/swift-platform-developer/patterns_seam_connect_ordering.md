# Seam connect ordering (fix-seam-connect-ordering)

## Root cause (the EPERM/ENOTCONN seam bug)

The old `TransportBridge.kickConnect` did `Task { try? await transport.connect(...) }`
(fire-and-forget, error swallowed) and the `ext.connect` trampoline returned `0`
**unconditionally**. libsmb2's `ext_connect` (transport-external.c) treats a `>= 0` return as
"connection established" and **synchronously fires `connect_cb` → NEGOTIATE**. So NEGOTIATE's
first `send()` hit `TCPTransportApple` while `_channel` was still nil → `POSIXError(.ENOTCONN)`
(errno 57). Handshake collapsed; libsmb2 reported status -1, mapped via `-(-1)=1` to
`POSIXError(.init(1))` == EPERM. The detached connect Task ran later into a torn-down event loop.

Contract libsmb2 relies on: **a `>= 0` connect return means the transport can carry bytes NOW.**

## The fix — eager connect (Approach A; Approach B rejected: it would block eventLoopQueue)

- `TransportBridge.connect(host:port:) async throws` awaits `transport.connect` then sets
  `isPreConnected = true` under the lock (via sync helper `markPreConnected()` — NSLock.lock() is
  unavailable in async bodies).
- `ext.connect` trampoline now returns `bridge.connectStatus()` = `isPreConnected ? 0 : -ECONNREFUSED`
  and does NO connect (exactly-once: transport connects only in `bridge.connect`).
- `Context.connectWithBridge` parses host/port via `SMB2Client.parseSeamEndpoint(_:)` and
  `await`s `bridge.connect(...)` **before** the `withCheckedThrowingContinuation`/
  `eventLoopQueue.async` block — so it runs on the caller's task, blocking no serialized work.
  Failure mapped via `mapTransportConnectError` and thrown with no operation registered.

### parseSeamEndpoint must mirror ext_connect byte-for-byte
`[ipv6]` → host up to `]` (missing `]` ⇒ `POSIXError(.EINVAL)`); after the optional `]` the FIRST
`:` splits host/port; port is leading decimal digits à la `strtol(...,10)` (0 if none); no `:` ⇒
445; no DNS. The `server` string is the IDENTICAL one libsmb2 hands to `ext_connect`
(`smb2->server`), so only parse logic must match.

### Teardown-on-early-failure (key A risk)
After `bridge.connect` succeeds the channel is live. The two guards in `connectWithBridge` that
return *before* the C close trampoline is wired — `context == nil` and `smb2_set_transport != 0` —
must `bridge.close()` (closes transport+pumps) IN ADDITION to balancing the `Unmanaged`. No
double-release: `bridge.close()` touches only transport/pumps; `Unmanaged.release()` balances the
bridge retain separately. The connect_share_async<0 / cancel / abandoned / timeout paths already
route through `teardownSeam() → bridge.close()`.

## Seam-only end-state gotcha: fileDescriptor == -1
A seam connection owns no native socket fd, so `smb2_get_fd == -1` ALWAYS, even when fully
connected. Any "is this connected?" check must use the seam-aware `isConnected`
(which checks `seamConnected` first), NOT `fileDescriptor != -1`. Fixed the public
`SMB2Manager.smbClient` accessor (AMSMB2.swift) which had used the fd predicate.

## Out-of-scope pre-existing bug found while validating
`SMB2ManagerTests.testStreamUploadDownload` truncates uploads at exactly 5 MiB. Cause:
`AsyncInputStream.read()` (Stream.swift:174) sets `_streamStatus = .atEnd` once the consumer
drains the currently-buffered bytes, WITHOUT checking whether the prefetch producer finished — the
"premature EOF when consumed faster than prefetch fills" race (already noted in CLAUDE.md). NOT a
seam I/O bug: `testLargeWriteThenRead` (5 MiB+7 via the data API) passes over the same seam. Needs
its own change to fix the AsyncInputStream EOF/would-block semantics.
