## Context

`SMB2Client.disconnect()` in `Context.swift:478` has a sequencing bug. It stops socket monitoring (sets `socketMonitor = nil`) before queuing the disconnect PDU via `async_await`. Since `async_await` relies on `socketMonitor?.activateWriteSourceIfNeeded()` to flush outgoing data and receive responses, the PDU is never delivered. The semaphore blocks for the full timeout (60s), then throws `ETIMEDOUT` which `try?` silently swallows.

The `shutdown()` method in the same file already handles disconnect correctly using a fire-and-forget pattern: queue the PDU with a no-op callback, flush once with `smb2_service(POLLOUT)`, then destroy resources.

## Goals / Non-Goals

**Goals:**
- Fix `disconnect()` so it completes promptly instead of blocking for 60s
- Send the disconnect PDU to the server (best-effort) before tearing down
- Maintain all thread-safety invariants (all libsmb2 calls on `eventLoopQueue`)

**Non-Goals:**
- Waiting for the server's disconnect response (fire-and-forget is sufficient)
- Changing the public `disconnectShare()` API
- Fixing unrelated issues in the disconnect path

## Decisions

### Fire-and-forget pattern (matching `shutdown()`) over reordered `async_await`

**Choice:** Replace the `async_await` call with inline `smb2_disconnect_share_async` + `smb2_service(POLLOUT)`, all inside a single `eventLoopQueue.sync` block.

**Rationale:**
- `shutdown()` already proves this pattern works correctly
- No semaphore, no timeout risk, no 60s penalty
- The `_=try?` on the original `async_await` call already reveals the intent was "best effort"
- Everything runs atomically on `eventLoopQueue` — no window for races

**Alternative rejected:** Moving `stopSocketMonitoring()` after `async_await`. This would fix the bug but adds unnecessary blocking (waiting for server response to a disconnect we don't inspect) and leaves the semaphore/timeout machinery in place for no benefit.

## Risks / Trade-offs

- **[Server may not process disconnect PDU]** → The single `smb2_service(POLLOUT)` flush is best-effort. If the TCP send buffer is full, the PDU may not be sent. The server will clean up the session via TCP FIN or session timeout regardless. This matches `shutdown()`'s existing behavior.
- **[No verification of clean session teardown]** → Acceptable because no caller inspects the disconnect result, and the `try?` pattern was already discarding errors.
