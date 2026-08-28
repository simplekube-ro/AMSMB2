# operation-cancellation-lifetime Specification

## Purpose
TBD - created by archiving change fix-cbdata-cancel-race-uaf. Update Purpose after archive.
## Requirements
### Requirement: CBData retain is released exactly once after a PDU is queued

The `CBData` retain handed to libsmb2 via `Unmanaged.passRetained` SHALL be released exactly once,
and only by `generic_handler` via `takeRetainedValue()`, once the operation's PDU has been queued.
No cancellation, timeout, or teardown path MUST release that retain after the PDU has been queued,
because libsmb2 is guaranteed to invoke the PDU's callback exactly once — on the network reply, or
during `smb2_destroy_context` (which fires every pending PDU's callback before freeing).

#### Scenario: Task cancellation observed after the PDU was queued

- **WHEN** a Swift `Task` running an `async_await` / `async_await_pdu` operation is cancelled in
  the window after the libsmb2 async call queued the PDU but before the setup block stored the
  continuation (`cb.isAbandoned == true` at the post-queue guard)
- **THEN** the setup block SHALL resume the continuation with `CancellationError` and SHALL NOT
  call `Unmanaged<CBData>.fromOpaque(cbPtr).release()`, leaving the single balancing release to
  `generic_handler`

#### Scenario: Late reply for a cancelled operation arrives on a live context

- **WHEN** libsmb2 later delivers the reply for an operation whose Swift task was cancelled (the
  PDU was still pending) and `generic_handler` runs during a normal servicing pass
- **THEN** `generic_handler` SHALL call `takeRetainedValue()` on a still-valid `CBData`, observe
  `isAbandoned == true`, and return without resuming any continuation — with no use-after-free

#### Scenario: Context destroyed while an abandoned operation is still pending

- **WHEN** `smb2_destroy_context` runs while a cancelled operation's PDU is still queued
- **THEN** libsmb2 SHALL fire the pending PDU's callback (`generic_handler`), which balances the
  `CBData` retain exactly once, so the object is neither leaked nor double-freed

#### Scenario: Cancelled seam connect with a pending NEGOTIATE is balanced at context destroy

- **WHEN** a seam `connectWithBridge` task is cancelled in the post-queue window so the abandoned
  branch runs after `smb2_connect_share_async` queued NEGOTIATE, the seam is torn down, and the
  client is later deallocated
- **THEN** the operation SHALL resume with `CancellationError`, the client SHALL NOT be left
  connected, and `smb2_destroy_context` SHALL fire `generic_handler` exactly once via libsmb2's
  internal connect callback chain — with no use-after-free and no double-free during teardown

### Requirement: CBData retain is balanced by the caller only before a PDU is queued

The setup code SHALL release the `CBData` retain itself if and only if no PDU was registered with
libsmb2 — the context was `nil`, the libsmb2 async/queue call threw or returned an error,
transport installation failed, or the connect call returned a negative result. In these cases
libsmb2 never received the `cbPtr`, so `generic_handler` MUST never be relied upon to balance it.

#### Scenario: Operation submitted with no live context

- **WHEN** the setup block finds `self.context == nil` before calling any libsmb2 async function
- **THEN** the setup block SHALL release the `CBData` retain and resume the continuation with
  `POSIXError(.ENOTCONN)`

#### Scenario: libsmb2 rejects the operation before queuing

- **WHEN** the libsmb2 async/queue/connect call throws or returns an error (no PDU queued)
- **THEN** the setup block SHALL release the `CBData` retain and resume the continuation with the
  corresponding error

### Requirement: Cancellation does not require a libsmb2 per-PDU cancel

The library SHALL remain correct without cancelling individual in-flight PDUs at the libsmb2
level. Swift `Task` cancellation only resumes the awaiting caller and marks the operation
abandoned; the underlying libsmb2 operation is allowed to complete or be aborted by
`smb2_destroy_context`, and `CBData`/read-buffer ownership SHALL be retained until that callback
fires.

#### Scenario: Cancelled read keeps its buffer and CBData alive for libsmb2

- **WHEN** a read operation's task is cancelled while libsmb2 still holds the read buffer pointer
  and the `cbPtr`
- **THEN** the read buffer SHALL be abandoned (not deallocated or returned to the pool) and the
  `CBData` retain SHALL be left intact, so libsmb2's eventual callback writes into and releases
  valid memory

### Requirement: Pending operations do not retain the client
A callback object registered with libsmb2 for an operation MUST NOT hold a strong reference to
its `SMB2Client`. Because libsmb2 holds the callback object until its reply arrives or the context
is destroyed, a strong reference would form a cycle through libsmb2's queues that keeps the
client — and therefore its context — alive for as long as the reply never arrives.

#### Scenario: Abandoned operation with no reply does not pin the client
- **WHEN** an operation has been queued to libsmb2, the awaiting caller has been resumed by
  cancellation, timeout, or disconnect, no reply ever arrives, and every external strong reference
  to the client is dropped
- **THEN** the client deallocates, its context is destroyed, and the pending callback object is
  released by the teardown sweep

#### Scenario: Completed operation still receives its result
- **WHEN** libsmb2 delivers the reply for a live (non-abandoned) operation
- **THEN** the caller-supplied result handler runs against the live client and the caller
  receives the decoded result exactly as before

### Requirement: Abandoned callback objects release captured state when libsmb2 balances the retain
When the libsmb2 callback fires for an operation that was already abandoned, the callback object
MUST release the closures it holds (result handler and cleanup) before returning, so that an
abandoned callback object cannot retain itself or any caller-captured state after libsmb2 has
released its reference.

#### Scenario: Abandoned seam connect is fully released at context destroy
- **WHEN** a seam connect is abandoned while its NEGOTIATE is pending and the context is later
  destroyed (by `disconnect()` or deallocation)
- **THEN** the connect's callback object is deallocated — the live callback-object count returns
  to its baseline — rather than surviving through a self-reference

### Requirement: Disconnect reclaims every pending callback object
`disconnect()` MUST cause libsmb2 to fire, and thereby balance, the retain of every callback
object still pending at the time of the call, before `disconnect()` returns. The retain MUST still
be balanced exactly once: the destroy-fired callback observes the abandoned state and returns
without resuming the caller a second time.

#### Scenario: Multiple reads in flight at disconnect
- **WHEN** N read operations are pending against a peer that never replies and `disconnect()` is
  called
- **THEN** all N callers receive `POSIXError(.ENOTCONN)` exactly once each, libsmb2 releases
  every one of the N retains before `disconnect()` returns, and the live callback-object count
  returns to its pre-read baseline once the callers' frames have released their own references
  (the per-operation timeout timer captures the callback object weakly and does not extend its
  lifetime)

#### Scenario: Integration — non-graceful disconnect mid-read releases the client
- **WHEN** a manager performs a non-graceful `disconnectShare` while a large read is in flight
  against a real server and a weak reference to the manager's client was captured beforehand
- **THEN** after the read's failure is observed the weak reference is nil and the live
  callback-object count has returned to its baseline
