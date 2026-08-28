# swift-platform-developer memory (AMSMB2)

## Build / test
- Always `--disable-sandbox`. Full suite baseline (no server env): **285 tests, 67 skipped, 0 failures**.
- Targeted: `swift test --disable-sandbox --filter <ClassName>/<testName>`.

## QUIC transport (AMSMB2/QUICTransportApple.swift)
- Driver-neutral seam `QUICConnectionState` (design D7) — no Network.framework types cross it.
  `QUICWaitClass { transient, fatal }` rides on `.waiting(POSIXError, QUICWaitClass)`; it is
  *preserved translation information* from the `NWError` case, policy lives in `handleState`.
- `NWConnection` reports a TLS/trust rejection as **`.waiting(.tls(status))`**, never `.failed`.
  `mapState` classifies `.tls` → `.fatal`; `handleState` routes fatal waits into `handleFailed`,
  which already covers connect-claim / commit-to-start parked loss / post-ready abnormal loss.
- TLS errors map to `POSIXError(.EPROTO)` with `NSUnderlyingErrorKey` =
  `NSError(domain: NSOSStatusErrorDomain, code: Int(status))`. `"\(NWError.tls(-9808))"` already
  prints the numeric status, so `NSLocalizedDescriptionKey: "QUIC TLS error: \(self)"` suffices.
- `NWError.tls(OSStatus)` / `.posix` / `.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchName))` are all
  constructible in tests with just `import Network` (dnssd comes along) — no seam shim needed;
  relax access to `internal` and use `@testable import AMSMB2`.

## Test doubles (AMSMB2Tests/QUICTransportAppleTests.swift)
- `ScriptedQUICDriver.emit(_:)`, `ManualDeadlineScheduler` (fires only on `fireNow()`, `cancelCount`),
  `GatedStartDriver` (captures `onState` **before** parking, so states can be emitted *inside* the
  commit-to-start window; `didEnterStart`/`releaseStart()`/`events`).
- For RED steps use `launchConnect` + `expectPromptPOSIX` + `reap` so a failing expectation is a
  bounded ~4.5 s failure, not a hung suite.
- `ManualDeadlineScheduler.fireNow()` resolves synchronously, so anything emitted after it loses the
  claim — the deadline's `ETIMEDOUT` description is built at claim time and cannot pick up later text.
