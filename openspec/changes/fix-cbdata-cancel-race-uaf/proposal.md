## Why

A real `EXC_BAD_ACCESS` (use-after-free) was captured on an iPad, crashing on the
`smb2_eventloop` queue inside `swift_retain` while libsmb2 delivered a pending read reply
(`read_cb` → `generic_handler`). Under heavy concurrent teardown (proxy sessions invalidated
mid-read, ~36 `sessionInvalidated`/timeout cancellations in the log), a per-operation `CBData`
is released while libsmb2 still holds its raw pointer in an outstanding PDU. When the slow
read's reply later arrives on a still-live, connected context, libsmb2 calls back into freed
memory and the process crashes. This is a pre-existing latent lifetime bug, not a hypothetical.

## What Changes

- Fix the `CBData` retain/release imbalance on the "cancellation observed *after* the libsmb2
  PDU was already queued" race branch. In `async_await` (`Context.swift:943`),
  `async_await_pdu` (`:1043`), and `connectWithBridge` (`:1308`), the code currently calls
  `Unmanaged<CBData>.fromOpaque(cbPtr).release()` even though `confinedHandler`/`smb2_queue_pdu`
  has already handed `cbPtr` to libsmb2. The premature release frees `CBData` out from under an
  in-flight operation. These three branches will **stop releasing** the retain and instead leave
  it to be balanced by the single `takeRetainedValue()` in `generic_handler` — which libsmb2 is
  guaranteed to fire exactly once (on the real reply, or on `smb2_destroy_context`, which fires
  every pending PDU's callback before freeing). This makes the racy branch behave identically to
  the already-correct `onCancel`/timeout paths, which abandon without releasing.
- Add regression coverage: a deterministic unit test asserting the post-queue cancellation branch
  does not free `CBData` before the callback fires (retain-balance invariant), and an
  integration stress harness (skipped without `SMB_SERVER`) that submits and cancels reads
  mid-flight in a tight loop to surface the race under ASan/TSan.

No public API changes. No behavioral change for callers (a cancelled read still throws
`CancellationError`); only the internal memory-ownership timing is corrected.

## Capabilities

### New Capabilities
- `operation-cancellation-lifetime`: Defines the memory-ownership contract for the `CBData`
  callback object across the full lifecycle of an async libsmb2 operation — registration,
  cancellation/timeout, completion, and context teardown — guaranteeing exactly one balanced
  release regardless of cancellation timing.

### Modified Capabilities
<!-- None: transport-connect-ordering's requirements are unchanged; only an internal ownership
     bug on the connect race branch is corrected, covered by the new capability above. -->

## Impact

- **Code:** `AMSMB2/Context.swift` — three cancellation branches in `async_await`,
  `async_await_pdu`, `connectWithBridge`. No signature changes.
- **Tests:** `AMSMB2Tests/` — new unit test for the retain-balance invariant; new integration
  stress test (skipped without a server).
- **Platforms:** Affects all platforms (the `async_await`/`async_await_pdu` branches are shared);
  the `connectWithBridge` branch is Apple-seam only (`canImport(Network)`).
- **Risk:** Low and localized. The change removes code on error/cancel branches; the retain is
  still balanced (by `generic_handler`, guaranteed by `smb2_destroy_context`'s teardown sweep).
  No double-free and no leak versus the existing `onCancel` path.
