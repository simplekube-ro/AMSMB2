## Context

See proposal.md — Why. Everything the probe needs already exists in `AMSMB2/QUICTransportApple.swift`
(Apple-only):

```
SMB2Client.connect(.quic)                 QUICTransportApple.connect(host:port:)
  parseSeamEndpoint(server, 443)            ├─ one-shot reservation, deadline always armed (ETIMEDOUT)
  isNumericHost → EINVAL                    ├─ task cancel → CancellationError
  1...65535     → EINVAL                    ├─ close() while connecting → ECONNABORTED
  normalizedQUICConnectTimeout              ├─ .waiting(_, .fatal) → handleFailed → EPROTO (+ NSUnderlyingErrorKey)
  QUICTransportApple(configuration:)        └─ .ready → ()
                                            close(): driver cancelled exactly once, waits for in-flight
                                                     connect work — "resources released when it returns"
driverFactory(host, port, QUICResolvedTrust) ─► NWConnectionQUICDriver
                                                  ALPN "smb", SNI = host, port guard
                                                  verify block per trust: none / complete(true) / customRoots
```

The transport's connect state machine (design D7/D12 of `add-quic-transport`) is a set of proven
claim/handoff/deadline/cancel/close guarantees; rc2's design records the constraint that these
proofs must not be re-derived. The internal initializer already injects a `driverFactory` and a
`ConnectDeadlineScheduler` for the scripted-double tests. Network.framework delivers a
`complete(false)` from a verify block as `.waiting(.tls(status))`, which rc2 classifies as a fatal
wait → `EPROTO` (observed `-9808` on Windows Server 2022 in ~0.2 s).

Constraints: errors are `POSIXError` only; no Security/Network types on the public surface; TDD
through the scripted-driver seam; surgical change — the connect state machine is not touched.

## Goals / Non-Goals

**Goals:**
- Implement the probe as a thin wrapper over the unchanged `QUICTransportApple` connect so every
  D7 race/teardown/deadline guarantee applies to it by construction.
- Keep ALPN/SNI/port/numeric-host rules in their single existing home; the probe adds no second
  copy of the wire contract.
- Deterministic unit coverage of every probe outcome through the existing driver/deadline seams,
  plus a unit-testable `SecTrust → [Data]` helper (no live handshake needed).

**Non-Goals:**
- Attaching the peer chain to connect-time `EPROTO` errors (issue #61, out of scope).
- Distinguishing hostname mismatch from chain failure under `.customRoots`.
- Any "trust automatically" behavior, persistence, or UI.
- An Objective-C entry point (the whole QUIC surface is Swift-only; can be added later if a
  consumer needs it).
- A new public `TrustPolicy` case — capture is not a policy a consumer may connect with.

## Decisions

### D1: The probe is a `QUICTransportApple.connect` that is expected to fail with `EPROTO`

The probe builds a `QUICTransportApple` through the **internal** initializer with a driver
factory that installs a capture-only verify block, calls `connect(host:port:)`, classifies the
result, and always `await close()`s before returning:

```
result of connect            chain in slot?      probe outcome
──────────────────────────   ─────────────────   ──────────────────────────────────────
throws EPROTO                yes                 return chain          (expected path)
throws EPROTO                no                  rethrow EPROTO        (ALPN mismatch, no cert)
throws ETIMEDOUT             yes                 return chain          (slow server, cert seen)
throws ETIMEDOUT             no                  rethrow ETIMEDOUT
throws CancellationError     any                 rethrow               (structured-concurrency etiquette)
throws EINVAL/other          no                  rethrow
throws EINVAL/other          yes                 return chain          (unreachable today: no handshake ran)
returns ()  (.ready)         yes                 return chain          (defensive: must not stay live)
returns ()  (.ready)         no                  throw EPROTO("no certificate captured")
ALWAYS: await transport.close()  → started driver cancelled exactly once, teardown complete on return
THEN:   read the capture slot     → after close() returned, so no verify-block write can still be in flight
```

Rule in one line: `CancellationError` always propagates; otherwise a captured chain wins over
any error; otherwise the transport's error is the probe's error.

Two precisions (review conditions 2, 3):
- The table keys on the **thrown error**, not on the `NWConnection` state shape. A
  `complete(false)` reaches the transport as `.waiting(_, .fatal)` *or* `.failed(_)`; both go
  through `handleFailed` and both land on the `EPROTO` row. The probe never inspects driver
  states.
- The slot is read only **after** `await close()` returns — `close()` guarantees the started
  driver was cancelled and its handlers cleared, so the read window is maximal and
  deterministic for the scripted tests. (The lock makes either order memory-safe; this is
  about determinism.)
- `close()` is cancellation-safe: it awaits only non-throwing continuations resumed from the
  teardown queue / `finishConnectWork`, with no `Task.checkCancellation()` on the path, so
  awaiting it from an already-cancelled task cannot hang or throw. "Always `await close()`,
  even on `CancellationError`" is therefore proven, not hopeful.
- Teardown accounting per path: fatal wait/failure/deadline → the loss path cancels the started
  driver once and nils it, so `close()` finds nothing to cancel; commit-to-start-window loss →
  the post-start handoff performs the single cancel and `close()` waits for it; `.ready` → the
  transport deliberately *retains* the driver, so the probe's `close()` is the one cancel (the
  `.ready` row is load-bearing, not merely defensive). One window performs **no** cancel by
  design: cancellation observed after the driver was constructed but before the continuation
  store never starts the driver (`testCancellationBeforeStartThrowsAndNeverStartsDriver`), so
  no connection exists to cancel. The spec's guarantee is phrased accordingly: a *started*
  driver is cancelled exactly once.

- Why: zero new state machine. `ETIMEDOUT`, `CancellationError`, `EPROTO` + underlying
  `OSStatus`, one-shot semantics, "cancel exactly once", "close waits for in-flight work" —
  all already implemented and tested. The probe is ~60 lines.
- Alternative rejected — a dedicated probe state machine over `QUICConnectionDriver` +
  `ConnectDeadlineScheduler` (the issue's sketch): would re-derive the D7 claim/handoff/deadline
  proofs for a second consumer; rc2's design explicitly forbids that. Any subset would either be
  incomplete (a race the transport already handles) or a copy.
- Alternative rejected — put the probe on `QUICTransportApple` as a static: ties a no-session
  operation to the availability-gated, Apple-only class, which breaks the platform-neutral
  surface requirement.

### D2: Capture is an internal resolved-trust mode, delivered through the driver factory

`QUICResolvedTrust` (internal) gains `case capture(QUICCertificateCaptureSlot)`. In
`NWConnectionQUICDriver.init` the new branch installs a verify block that does
`sec_trust_copy_ref` → `Self.certificateChainDER(from: SecTrust)` → `slot.store(chain)` →
`complete(false)`. Nothing else in the driver changes, so ALPN/SNI/port guard stay in one place
(no `NWParameters` extraction needed — the issue proposed one under the assumption the probe
would build its own connection).

The probe's driver factory ignores the `trust` argument the transport passes
(`resolveTrust(.system)` → `.system`) and builds `NWConnectionQUICDriver(host:port:trust: .capture(slot))`.

- Why ignore rather than override: the seam was designed for injected factories and the probe is
  simply the first non-test caller of the internal initializer; the transport gains no new stored
  state or init parameter. `SMBQUICConfiguration`/`TrustPolicy` stay untouched, so the public
  "three mutually exclusive policies" contract in `quic-transport-apple` is unaffected.
- Alternative rejected — `trustOverride: QUICResolvedTrust?` stored on the transport: ~5 lines,
  but it adds a state field and an init parameter to a class whose invariants are heavily
  documented, for one caller.
- Alternative rejected — a public `TrustPolicy.captureOnly`: would let a consumer *connect* with a
  policy that can never succeed, and would put the slot (a reference type) into an `Equatable`
  value type.

What the transport still does, explicitly: `QUICTransportApple.connect` computes
`resolveTrust(.system)` → `.system` and passes it to the factory, which **discards** it. The
`quic-transport-apple` guarantee "Under `.system`, the transport SHALL install no custom verify
logic at all" is scoped to the *production* driver factory (the public initializer) and is
unaffected; the capture mode is internal and unreachable from any public configuration (the
probe spec states this). The probe constructs its configuration truthfully — it normalizes once
(`let connectTimeout = try SMB2Client.normalizedQUICConnectTimeout(timeout)`) and passes that
same value both as `SMBQUICConfiguration(trustPolicy: .system, connectTimeout: connectTimeout)`
and as the internal initializer's `connectTimeout:` — so no dead or un-normalized deadline value
sits next to the armed one.

Why not the issue's `NWParameters` extraction: it was proposed under the assumption that the
probe builds its own `NWConnection`. Because D1 reuses the transport, an extracted builder would
be a second symbol with no second consumer — exactly what the dead-code rule forbids.

`QUICCertificateCaptureSlot` is a tiny internal `final class … : @unchecked Sendable`
(NSLock-guarded `[Data]?`, the same pattern as `DispatchDeadlineScheduler`; `store` ignores an
empty chain, so "chain in slot?" in the D1 table means exactly "a non-empty chain was captured"
and the verify block needs no guard of its own) — it is captured by
the verify block (runs on the driver's `verifyQueue`), by the probe's driver-factory closure, and
held across the `await connect` suspension, so Swift 6 strict concurrency requires the
conformance. The lock supplies the memory barrier for the cross-queue read. Ordering: the verify
block writes the slot before calling `complete(false)`, and Network.framework reports
`.waiting(.tls)` only after the completion, so the slot is filled before the transport can
observe the rejection.

### D3: `SecTrust → [Data]` is a factored, unit-testable helper

`static func certificateChainDER(from trust: SecTrust) -> [Data]` uses
`SecTrustCopyCertificateChain` (iOS 15 / macOS 12 — the QUIC floor) and
`SecCertificateCopyData`, leaf first; a `nil` chain from `SecTrustCopyCertificateChain` yields an
empty array, which the verify block treats as "nothing captured" (the `EPROTO` row). Unit-tested against a `SecTrust` built with
`SecTrustCreateWithCertificates` from `openssl`-generated certificates — the same approach
`QUICTrustTests` already uses for `evaluateCustomRootsTrust` (skips when `openssl` is absent). The production verify block is covered at the interop
gate (chain SHA-256 equals the server `.cer`).

- Known subtlety: `SecTrustCopyCertificateChain` returns the chain *as Security.framework sees
  it* and may evaluate to build it. For self-signed and private-CA servers (the motivating
  cases) that is exactly what was sent; against a publicly-trusted server it may append a system
  root the server did not send — harmless for TOFU (see Open Questions for the doc wording).

### D4: Endpoint validation is factored, not duplicated — without a second parse in `connect`

`SMB2Client.connect(.quic)` currently inlines numeric-host → port-range after the single
`parseSeamEndpoint` call whose result it also needs for `connectWithBridge` ("`parseSeamEndpoint`
is invoked exactly once" is a documented invariant of that method). So the factoring is split
in two, both in `Context.swift`'s `#if canImport(Network)` region next to `parseSeamEndpoint`:

- `static func validateQUICEndpoint(host: String, port: Int) throws` — the numeric-host and
  1...65535 checks; `connect`'s `.quic` branch calls it on its already-parsed pair (invariant
  preserved, behavior identical).
- `static func validatedQUICEndpoint(_ server: String) throws -> (host: String, port: Int)` —
  `parseSeamEndpoint(server, defaultPort: seamDefaultPort(for: .quic))` then
  `validateQUICEndpoint`; the probe's single entry point.

Both are Apple-only, which is fine: the Linux probe body throws `ENOTSUP` before any validation,
so on Linux a numeric host yields `ENOTSUP`, not `EINVAL` — the same ordering as
`SMB2Manager.connectShare`'s up-front `.quic` rejection. Timeout normalization stays a separate
call (`normalizedQUICConnectTimeout`) because the two callers source it differently
(`SMBQUICConfiguration.connectTimeout` vs the probe's `timeout` parameter). Two real call sites
justify each helper; the existing `QUICSeamConnectTests` keep covering the connect side.

### D5: Public surface — `SMBQUICCertificateProbe` caseless enum, `server:` label, 8 s default

```swift
@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)
public enum SMBQUICCertificateProbe {
    public static func fetchServerCertificateChain(
        server: String, timeout: TimeInterval = 8
    ) async throws -> [Data]
}
```

- Declared in a new `SMBQUICCertificateProbe.swift` on every platform; the body is
  `#if canImport(Network)` … `#else` throw `ENOTSUP` (Glibc constant, the same pattern as
  `SMB2Manager.connectShare`'s Linux `.quic` rejection). Consumers therefore compile without
  `#if` and get the same runtime code as `.quic` connect on Linux.
- The availability attribute makes "below the floor" a **compile-time** condition, matching
  `QUICTransportApple`; the issue's "throws `ENOTSUP` below the floor" is unreachable and is
  replaced by the compile-time gate (the spec says so).
- `server:` rather than the issue's `host:` — the argument is a `host[:port]` server string;
  `host` would be actively misleading public API. The internal precedents are
  `SMB2Client.connect(server:)` / `parseSeamEndpoint(_ server:)`; the only *public* precedent is
  `SMB2Manager(url:)`, so there is no public label to be consistent with either way — which
  means the doc comment must spell out the grammar itself (`"fs.example.com"`,
  `"fs.example.com:4433"`, UDP/443 default) rather than refer the reader to `SMB2Manager`.
- 8 s default (issue) rather than `SMBQUICConfiguration`'s 30 s: the probe is interactive (a
  user is waiting on a "fetch certificate" button); a TLS rejection arrives in ~0.2 s, and a
  UDP black hole should not stall the UI for 30 s. `docs/API.md` states that the two deadlines
  are independent and why, since both appear there.

### D6: Internal test entry point mirrors the transport's

`static func fetchServerCertificateChain(server:timeout:driverFactory:deadline:)` (internal)
takes a probe-specific `driverFactory: (host, port, QUICCertificateCaptureSlot) -> any QUICConnectionDriver`
and a `ConnectDeadlineScheduler`; the public method calls it with the production factory and
`DispatchDeadlineScheduler`. Tests receive the slot, so the scripted double can pre-fill it (or
not) before emitting `.waiting(EPROTO, .fatal)`, `.ready`, or firing the deadline, and can assert
`cancelCount == 1` on every exit path. No new seam protocols.

## Risks / Trade-offs

- [`SecTrustCopyCertificateChain` triggers evaluation and appends a system root on
  publicly-trusted servers] → Only affects a case TOFU does not need; documented as "the chain as
  presented to Security.framework, leaf first"; interop asserts exact equality on the
  self-signed target.
- [A server that accepts despite `complete(false)`] → Impossible with TLS 1.3 semantics, but the
  `.ready` row in D1 closes the connection regardless and is covered by a scripted-driver test.
- [Deadline shorter than the handshake but after capture returns a chain instead of `ETIMEDOUT`]
  → Deliberate (D1): the consumer asked for the chain and got it; documented in the spec.
- [Capture slot filled but `CancellationError` propagates] → Deliberate; a cancelled task must
  not observe a success value. The consumer can re-probe.
- [Probe reserves the transport's one-shot attempt] → Each probe builds a fresh transport; the
  one-shot rule is invisible to the caller.
- [The production capture wiring (`sec_trust_t` → slot) cannot be unit-tested] → `sec_trust_t`
  is not constructible in a test; the branch is verified by code inspection plus the interop
  gate, while the `SecTrust → [Data]` conversion and the slot are unit-tested — the same
  arrangement the `.system` no-verify-block scenario already records in `quic-transport-apple`.
- [TOFU steps around secure-by-default] → The docs carry the first-contact caveat as a spec'd
  requirement (`api-reference` delta): an on-path attacker can present their own chain, so the
  SHA-256 must be confirmed out of band before persisting, and the anchor replaces the system
  roots for that connection.
- [Verify block retains the slot after the probe returned] → `close()` clears the driver's
  handlers; the slot is a tiny value holder with no back-reference, so a late-firing block
  (if any) writes to an orphan and is dropped.

## Migration Plan

Purely additive; no migration. Rollback is reverting the commit. Release as 6.0.0-rc3.

## Open Questions

- Exact doc wording for what `SecTrustCopyCertificateChain` returns against a publicly-trusted
  server (whether a system root is appended). Resolve at the interop gate by probing one public
  QUIC endpoint if convenient; does not change the API, specs, or tasks — only a sentence in
  `docs/API.md`.
