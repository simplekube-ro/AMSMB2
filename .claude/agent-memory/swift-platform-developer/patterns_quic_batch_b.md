---
name: patterns-quic-batch-b
description: QUICTransportApple (add-quic-transport Batch B) — D7 connect state machine, D8 lifecycle, injected seams, TLS trust, test-cert generation
metadata:
  type: project
---

# QUICTransportApple (add-quic-transport Batch B, tasks 2.2–2.6)

`AMSMB2/QUICTransportApple.swift` — `#if canImport(Network)`, `@available(iOS 15, macOS 12,
macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)` (macCatalyst explicit per D1; **all 3**
gated decls — class, `NWConnectionQUICDriver`, `NWError` ext — must carry the SAME floor incl.
watchOS 8). Mirrors TCPTransportApple's `@unchecked Sendable` + single-`NSLock` shape (D3).

## Injected seams (D7) — the key to deterministic testing
- `protocol QUICConnectionDriver` (start(onState:onReceive:) / cancel / send). Production =
  `NWConnectionQUICDriver` (thin NWConnection wrapper, self-re-arming receive). Test =
  `ScriptedQUICDriver` that records cancel()/start and emits state+inbound on demand, NEVER
  auto-emits `.cancelled` (tests own every interleave).
- `protocol ConnectDeadlineScheduler` (schedule(after:fire:) / cancel). Production =
  `DispatchDeadlineScheduler` (DispatchSourceTimer). Test = `ManualDeadlineScheduler.fireNow()`;
  its `cancel()` only COUNTS (keeps the fire closure) so a post-ready `fireNow()` proves the
  deadline is a no-op after ready.
- Injected via an internal `init(configuration:connectTimeout:driverFactory:deadline:)`; the
  public `init(configuration:connectTimeout:)` uses production collaborators. **ExistentialAny
  is ON project-wide** → every protocol-as-type needs `any` (`(any QUICConnectionDriver)?`,
  `-> any QUICConnectionDriver`, `(any DispatchSourceTimer)?`), else new warnings fail the gate.

## D7 connect: atomic claim (`resolveConnect(_:)`)
One lock section: `guard case .connecting(let cont) = connectState` (loser → nil → NO side
effects). `.ready` → keep driver, everReady=true; losing outcomes (.failed/.taskCancelled/
.closed/.deadline) → clear+cancel driver. Winner (outside lock): `deadline.cancel()` always;
cancel driver only on losing outcome; resume once. Error contract: taskCancel→CancellationError,
close→ECONNABORTED, deadline→ETIMEDOUT (desc folds in last `.waiting`), failed→mapped POSIXError.
Cancel-before-store race: inside the continuation body, re-check `Task.isCancelled`/`isClosed`
UNDER the lock before storing `.connecting` (else onCancel fires before store → orphaned cont).
`try Task.checkCancellation()` at top handles cancel-before-start.
**Start-after-claim gate (review should-fix):** `driver.start()`+`deadline.schedule()` run AFTER
the store lock releases, so a close()/deadline winner in that window must not cause the setup body
to start anything. Fix: a lock-guarded `driverStarted` flag — the setup body arms the deadline,
then re-checks the claim under the lock (`guard case .connecting`; sets `driverStarted=true`) and
starts ONLY if still connecting; every losing winner cancels the driver only `driverStarted ?
driver : nil`. (A cross-thread onCancel/close/deadline CAN run concurrently with the setup body;
the lock-protected gate — not any "the body is synchronous" assumption — is what makes every
interleaving safe.)
Deterministic regression: an `ImmediateFireScheduler` whose `schedule()` calls `fire()`
synchronously → deadline wins the claim before start → `driver.didStart==false`, `cancelCount==0`,
connect throws ETIMEDOUT. Also: `NWConnectionQUICDriver.cancel()` nils `stateUpdateHandler` +
`onReceive` (design D7 "clears the stored reference and its stateUpdateHandler").

## D8 established lifecycle (`ready → localClosing → closed | failed`)
Discriminator = recorded cause. `close()` records local-close cause UNDER the lock BEFORE
`driver.cancel()`, so the resulting `.cancelled` event sees non-`.active` lifecycle → no-op ack.
Post-ready `.failed`, or `.cancelled` with lifecycle still `.active` (no local close) → abnormal
loss (parked/next receive throws mapped POSIXError). receive() ordering: drain inboundChunks →
`isClosed`→empty (close contract wins over a prior error, per D8) → receiveError → inboundEOF →
`!everReady`→ENOTCONN → park. Peer EOF = empty-Data inbound delivery. close() records
`.localClosing` then `.closed` in one lock section (both cosmetic-distinct per spec; only
"non-`.active`" matters). ENOTCONN reserved for never-connected (never `.ready`, never closed).

## TLS trust (D5)
- `resolveTrust(policy, host)` runs EAGERLY in connect() before the driver exists: `.customRoots`
  converts every DER via `SecCertificateCreateWithData` → `EINVAL` on invalid DER AND on
  `.customRoots([])`. Returns `QUICResolvedTrust` {system, customRoots(anchors,host), insecure}.
- `evaluateCustomRootsTrust(trust,host,anchors)` (static, testable): SecPolicyCreateSSL(true,host)
  → SecTrustSetPolicies → SecTrustSetAnchorCertificates → SecTrustSetAnchorCertificatesOnly(true)
  → check every OSStatus (fail closed) → SecTrustEvaluateWithError.
- Verify-block (production): `.system` installs NONE; `.insecure` completes(true); `.customRoots`
  gets SecTrust via `sec_trust_copy_ref(trustRef).takeRetainedValue()` (Unmanaged→+1; NOT
  sec_protocol_metadata_copy_sec_trust) then evaluateCustomRootsTrust.

### Test-cert generation gotcha (important)
Apple's SSL policy caps TLS cert validity (~398 days for notBefore≥2020-09) → a COMMITTED DER
fixture EXPIRES and a 20-yr cert is rejected ("exceeds maximum temporal validity period"). So
generate certs at TEST RUNTIME via `openssl req -x509 -days 300` (always valid), XCTSkip if
openssl missing. Cert MUST be `basicConstraints=CA:FALSE` + `extendedKeyUsage=serverAuth` +
`subjectAltName=DNS:<cn>` or self-anchor eval returns false. Parse PEM→DER in Swift (strip
BEGIN/END, base64-decode) to avoid a 2nd openssl call. Verified matrix: correct-host→true,
wrong-host→false, wrong-anchor→false.

## 2.6 wiring
Context.swift `.quic` branch: validate (numeric→EINVAL, timeout→EINVAL) then
`if #available(... watchOS 8 ...) { transport = QUICTransportApple(configuration: quicConfiguration
?? SMBQUICConfiguration(), connectTimeout: normalizedTimeout) } else { throw ENOTSUP }`. Selector
SMB2_TRANSPORT_QUIC already plumbed (Batch A). Removed the Batch-A ENOTSUP-stub tests that are now
obsolete (a validated non-numeric `.quic` now does a REAL connect — not unit-testable
deterministically; covered by seams + interop). Kept validation-layer EINVAL tests only.

## Test-double async gotchas
`DispatchSemaphore.wait()` is UNAVAILABLE in async contexts (only `.signal()` works) → to gate a
sync factory closure from an async test, use a lock-guarded `TestFlag` + `waitUntil` poll, and
`.wait()` only INSIDE the sync factory. POSIXError description is stored in
`NSLocalizedDescriptionKey` → read via `(posix as NSError).localizedDescription`.
Counts: QUICTransportAppleTests 21, QUICTrustTests 6. Full suite 216 macOS / 127 Linux, 0 fail.
