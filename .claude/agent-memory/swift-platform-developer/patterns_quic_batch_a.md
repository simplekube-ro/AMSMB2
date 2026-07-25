# QUIC transport Batch A (add-quic-transport tasks 2.1, 1.1–1.5)

## Files
- `AMSMB2/SMBQUICConfiguration.swift` — platform-neutral (Foundation only, NO `#if canImport(Network)`).
  `TrustPolicy` enum (`.system`/`.customRoots([Data])`/`.insecureNoVerification`) makes
  "roots + insecure" unrepresentable. DER `[Data]` anchors + `TimeInterval` → compiles on Linux.
- `AMSMB2/QUICConnectionPolicy.swift` — platform-neutral `extension SMB2Client` holding the pure
  policy helpers `isNumericHost` + `normalizedQUICConnectTimeout`. Placed OUTSIDE the Network guard
  so Linux compiles/tests them (the `.quic` path that USES them is Apple-only, but the helpers are pure).
- Seam plumbing (`seamDefaultPort`/`seamSelector`/`parseSeamEndpoint(defaultPort:)`/
  `connect(...quicConfiguration:)`/`connectWithBridge(host:port:selector:)`/`BridgeOwnershipHandoff`)
  all live in the `#if canImport(Network)` region of Context.swift.

## isNumericHost (design D4)
`getaddrinfo(host,nil,&hints,&res)` with `AI_NUMERICHOST`, `AF_UNSPEC`; `freeaddrinfo` on 0-return.
Darwin's getaddrinfo already classifies EVERY required numeric form (127.1, 2130706433, 0x7f000001,
0177.0.0.1, fe80::1%en0, ::ffff:x) — verified with a C probe. Kept a fail-closed supplement anyway
(strip `%zone` → `inet_pton(AF_INET6)`; then `inet_aton` for legacy IPv4) per D4. Empty host → `true`
(rejected) so ONE caller-side `if isNumericHost {throw EINVAL}` covers both numeric and empty.

### Linux SOCK_STREAM gotcha (compile break)
On Glibc `SOCK_STREAM` imports as the `__socket_type` ENUM, not `Int32` (Darwin imports it as Int32).
`hints.ai_socktype = SOCK_STREAM` fails to compile on Linux. Fix:
`#if canImport(Glibc) hints.ai_socktype = Int32(SOCK_STREAM.rawValue) #else … = SOCK_STREAM #endif`.
`AF_UNSPEC`/`AF_INET6` are macros (Int32) on both — no split needed. Verified via `make linuxtest`
(volume-mount variant; `cleanlinuxtest` fails — Dockerfile doesn't COPY the libsmb2 submodule; and
`make linuxtest` itself breaks on `-v .:` → run `docker run --rm -v "$(pwd)":/home/nonroot/src/app linuxtest`).

## connect() restructure (D4)
`connect(server:share:user:transportKind:quicConfiguration: SMBQUICConfiguration? = nil)` — default
`nil` keeps the batch-A manager caller (`transportKind:.automatic`) compiling unchanged. Order: parse
ONCE with per-kind defaultPort → `.quic` branch validates host (numeric→EINVAL) then timeout
(`normalizedQUICConnectTimeout`→EINVAL) BEFORE constructing transport → Batch-A `.quic` throws
`POSIXError(.ENOTSUP,"QUIC transport pending")` where the transport would be built (selector=QUIC dormant).
`transport` is `let` assigned only in tcp/automatic; quic path throws before use (definite-assignment OK).

## normalizedQUICConnectTimeout (D10)
`guard value.isFinite, value>0 else EINVAL; return min(value,3600)`. NaN/±inf/0/neg→EINVAL; 3600
unclamped; sub-second passes. Independent of `SMB2Client.timeout` (which still gates `smb2_set_timeout`
only when >0). Batch A can't test end-to-end "deadline armed" (stub), so independence is asserted via:
timeout=0 client + valid quic config non-numeric host → reaches ENOTSUP (not EINVAL).

## D12 BridgeOwnershipHandoff (task 1.5) — the important one
Internal `final class @unchecked Sendable`, NSLock + manual lock/defer (NOT `.withLock` — matches
TransportBridge, avoids the macOS-13 availability question). States:
`eagerConnecting→localOwned→installing→installed` + terminal `cancelled`/`finished`. Claim-assigns-duty
shape (mirrors D7 claimConnectOutcome): winner performs close/cleanup OUTSIDE the lock → bridge closes
exactly once on every path.

Methods & the ONE outer `withTaskCancellationHandler` in connectWithBridge:
- `try Task.checkCancellation()` first (cancel-before-start; nothing connected → nothing to close).
- eager `bridge.connect` inside the handler (was outside before). Capture success/failure into
  `eagerFailure`, do NOT throw yet.
- `reconcile(connectFailed:)` — ONE lock txn: state `cancelled`→`.cancellationWon` (rows B/C AND race-E
  cancellation-first: cancellation wins regardless of connect result); `eagerConnecting`+fail→`.eagerFailed`
  (row D); `eagerConnecting`+success→`.proceed` (row A). Caller: cancellationWon→`bridge.close()`+throw
  `CancellationError()`; eagerFailed→`bridge.close()`+throw `mapTransportConnectError(err)` (NEVER
  CancellationError); proceed→continue.
- install block FIRST line: `guard handoff.claimInstalling() else {resume CancellationError;return}` —
  a failed claim (state already `cancelled` via onCancel@localOwned) creates NOTHING: no `cbPtr`, no
  `passRetained(cb)`, no `makeExternalTransport()`, no libsmb2 call. Only a true claim builds cbPtr etc.
- `markInstalled()` right after `transportBridge = bridge`; install-failure paths call `markFinished()`
  and release ONLY what was created (context-gone: cbPtr only; set_transport fail: +ext.userdata retain;
  connect_share<0: teardownSeam).
- `onCancel` → `handoff.cancel()`: eagerConnecting→`.noClose` (reconciliation closes); localOwned→
  `.closeLocalBridge` (close now); installing/installed→`.installedTeardown` (existing abandon+teardownSeam
  on eventLoopQueue — queue serialization guarantees install block finishes first); terminal→`.noClose`.

Row C normalization is the KEY subtlety: TCPTransportApple maps task-cancel to `POSIXError(.ECANCELED)`
(not CancellationError) — reconciliation must normalize any cancelled-state outcome to CancellationError.

### Testing D12
- Transition-table unit tests hit every row/both race-E orders with NO real cancellation timing (just
  call cancel()/reconcile()/claimInstalling() in sequence, assert returned duty + `currentState`).
  Added test-only `var currentState` on the handoff.
- Wired connectWithBridge tests need a gated actor transport (`GatedOutcomeTransport`: connect parks on a
  gate until `openGate()`, then succeeds/throws; counts `close()`). Deterministic cancellation-win:
  `await waitUntilConnecting(); task.cancel(); await openGate()` — task.cancel() runs onCancel SYNC before
  gate opens, so `cancelled` commits before reconcile. close() is async (bridge fires `Task{await
  transport.close()}`) → poll `await transport.closeCount == 1`.
- Added internal `var hasInstalledSeamBridge {syncOnEventLoop{transportBridge != nil}}` (sibling of
  `pendingSeamOperationCount`) so tests assert transportBridge==nil after a cancellation/eager-failure win.

## Existing callers updated (same-task, no dead code)
`connectWithBridge` old sig had no host/port/selector → updated SMB2ServicingLoopTests (4),
SMB2CBDataLifetimeTests (1), SMB2SeamConnectOrderingTests (1) + parseSeamEndpoint calls (add
`defaultPort:445`). Tests without `import SMB2` use `SMB2Client.seamSelector(for: .automatic)` for the
selector (returns Int32, no SMB2 import needed).
