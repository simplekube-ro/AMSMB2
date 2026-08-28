## ADDED Requirements

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
  returns to its pre-read baseline (immediately when no per-operation timeout timer is armed,
  otherwise once the timer holding the abandoned object fires)

#### Scenario: Integration — non-graceful disconnect mid-read releases the client
- **WHEN** a manager performs a non-graceful `disconnectShare` while a large read is in flight
  against a real server and a weak reference to the manager's client was captured beforehand
- **THEN** after the read's failure is observed the weak reference is nil and the live
  callback-object count has returned to its baseline
