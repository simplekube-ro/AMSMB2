## Why

Since rc2 (`quic-fail-fast-on-tls-rejection`, issue #59) a consumer learns in ~0.2 s *that* an
SMB-over-QUIC server's certificate was rejected (`POSIXError(.EPROTO)`), but nothing exposes the
chain the server presented, so the obvious next affordance — "trust this certificate?"
(trust-on-first-use) — is impossible to build. The self-signed lab shape is real and common (the
Windows Server 2022 interop target serves a self-signed leaf that works as its own `.customRoots`
anchor), and today the only way to get that leaf onto an iPhone or Apple TV is to export a `.cer`
on the server and sneakernet it. Consumers must not reconstruct the handshake themselves: the
ALPN/SNI/port/numeric-host rules are this library's wire contract, and a second copy in an app
cannot use the driver seam for tests. Tracked as
[issue #61](https://github.com/simplekube-ro/AMSMB2/issues/61); target **6.0.0-rc3**.

## What Changes

- A new public, platform-neutral entry point performs one SMB-over-QUIC TLS handshake against a
  `host[:port]` server string with a **capture-only** verify step and returns the DER-encoded
  certificate chain the server presented, leaf first, as `[Data]`. The verify step never
  completes successfully, so the handshake is torn down before any application data flows; no
  SMB session is created and the peer is never trusted.
- The probe applies exactly the same pre-connect validation as `.quic` connect (numeric host and
  out-of-range port → `EINVAL`; 443 default port; explicit port honored) and the same
  connect-timeout normalization, so the two surfaces cannot drift.
- Outcomes are expressed with the existing error vocabulary: chain captured → `[Data]`;
  handshake rejected before a certificate was delivered → `EPROTO` with the
  `NSOSStatusErrorDomain` underlying error; unreachable/unresponsive within `timeout` →
  `ETIMEDOUT`; task cancellation → `CancellationError`; Linux → `ENOTSUP`. Below the Apple
  availability floor the symbol is unavailable at compile time, exactly like
  `QUICTransportApple`.
- The probe never leaves a QUIC connection alive after it returns, on any path (including a
  server that unexpectedly accepts the handshake).
- Purely additive: connect semantics, `SMBQUICConfiguration`, and the `TrustPolicy` cases are
  unchanged. Security.framework types stay out of the public surface. Swift-only, like the rest
  of the QUIC surface.
- Documentation: `docs/API.md` gains the type and a trust-on-first-use section; `README.md`'s
  QUIC section gains the TOFU snippet; `docs/ARCHITECTURE.md`'s type and file tables gain the
  new symbol/file; `docs/INTEROP-QUIC.md` records the Windows Server 2022 probe run.

## Capabilities

### New Capabilities
- `quic-certificate-probe`: capture-only retrieval of the server certificate chain a
  SMB-over-QUIC endpoint presents — inputs, validation, outcomes, and the never-trust /
  never-leave-a-connection-alive guarantees.

### Modified Capabilities
- `api-reference`: the "All public types documented" requirement gains the new public type, the
  Swift-only note, and the trust-on-first-use guidance including its first-contact caveat; the
  "Error documentation" requirement gains the probe's `ETIMEDOUT`/`EPROTO`/`ENOTSUP`/`EINVAL`
  meanings (and that below the Apple floor the symbol is compile-time unavailable).

## Impact

- **New file** `AMSMB2/SMBQUICCertificateProbe.swift` — the public entry point (declared on every
  platform; Apple body under `#if canImport(Network)`, Linux body throws `ENOTSUP`) and the
  internal capture slot.
- `AMSMB2/QUICTransportApple.swift` — the internal resolved-trust enum gains a capture-only
  mode; `NWConnectionQUICDriver` installs a verify block for it that stashes the DER chain and
  completes `false`; a small `SecTrust → [Data]` helper factored for unit testing. No change to
  the connect state machine, the public initializer, or the public `TrustPolicy`.
- `AMSMB2/Context.swift` — the `.quic` branch's numeric-host + port-range validation is factored
  into an internal helper shared with the probe (plus a parse-then-validate wrapper for the
  probe); `connect` still parses exactly once (behavior unchanged).
- **Tests**: new `AMSMB2Tests/SMBQUICCertificateProbeTests.swift` (scripted-driver cases and
  the `SecTrust → DER` helper); new interop cases in `AMSMB2Tests/SMB2QUICInteropTests.swift`
  (probe leaf SHA-256 matches the new optional `SMB_QUIC_LEAF_DER`; the probed DER connects as
  `.customRoots`; TCP-only host negative).
- **Docs**: `docs/API.md`, `README.md`, `docs/ARCHITECTURE.md`, `docs/INTEROP-QUIC.md`.
- **Dependencies**: none added. Uses `SecTrustCopyCertificateChain` (iOS 15 / macOS 12 —
  identical to the QUIC availability floor).
- **Consumer (RandomPlayer)**: unblocks the "Get certificate from server → show subject / SAN /
  validity / SHA-256 → user confirms → persist as `.customRoots` anchor" flow.

## Review

**Verdict:** APPROVED WITH CONDITIONS
**Reviewer:** project-architect
**Date:** 2026-08-29

D1 is the right call and I endorse it: making the probe a thin classifier over an unchanged
`QUICTransportApple.connect` inherits every D7/D8/D12 claim/handoff/deadline/teardown proof by
construction, which is exactly what rc2's design demanded and what the issue's "dedicated probe
state machine" sketch would have violated. D2 (capture as an internal `QUICResolvedTrust` mode
delivered through the existing injected `driverFactory`) is likewise correct — it adds no stored
state to a class whose invariants are heavily documented, keeps ALPN/SNI/port in their single
home, and keeps the public `TrustPolicy` contract untouched; ignoring the `trust` argument is
acceptable because the seam was built for injected factories and the probe is simply its first
non-test caller. I traced the outcome table against `resolveConnect`/`consumeLossClaimLocked`/
`close()` and it is sound (see O1). The conditions below are gaps in artifact precision, one
Swift 6 conformance that will not compile as written, one refactor that collides with a
documented invariant, and one interop assertion that is wrong against the private-CA rig — none
of them change the shape of the design.

### Conditions (address before `/opsx:apply` completes; artifacts must reflect them)

1. **`QUICCertificateCaptureSlot` must be declared `@unchecked Sendable`.** It is captured by the
   verify block (driver `verifyQueue`), by the probe's driver-factory closure, and held across the
   `await connect` suspension; a plain `final class` fails under Swift 6 strict concurrency. State
   it in D2 and task 1.4.

2. **Pin two under-specified points of the D1 outcome table.** (a) Say the slot is read *after*
   `await close()` returns. (b) Say the table keys on the thrown error, not the `NWConnection`
   state — a `complete(false)` can arrive as `.waiting(_, .fatal)` or `.failed(_)`, both routed
   through `handleFailed` to the `EPROTO` row.

3. **"Never leaves a connection alive" overclaims.** Cancellation observed after `driverFactory`
   ran but before the continuation store never starts the driver and never cancels it
   (`testCancellationBeforeStartThrowsAndNeverStartsDriver` asserts `cancelCount == 0`). Reword
   the requirement to "a *started* driver is cancelled exactly once"; scope task 2.1's
   `cancelCount == 1` to started cases and add a cancel-before-start case.

4. **D4's extraction collides with `connect`'s "parse exactly once" invariant.** Split into
   `validateQUICEndpoint(host:port:)` (called by `connect` on its parsed pair) and
   `validatedQUICEndpoint(_ server:)` (parse + validate, the probe's entry); both Apple-only
   inside the `#if canImport(Network)` region. Update tasks 1.1/1.2.

5. **Make the probe's `SMBQUICConfiguration` truthful and document the discarded trust.**
   Construct `SMBQUICConfiguration(trustPolicy: .system, connectTimeout: timeout)`; state in D2
   that `connect` still computes `resolveTrust(.system)` and the factory discards it, that the
   `quic-transport-apple` "`.system` installs no verify logic" guarantee is scoped to the
   production factory, and add to the probe spec that the capture mode is unreachable from any
   public configuration.

6. **Task 3.1's SHA-256 assertion is wrong against the private-CA rig** (`SMB_QUIC_CA_DER` is the
   lab CA; CA == leaf only on the self-signed Windows target). Introduce a dedicated expected-leaf
   env var or gate the equality on a self-signed flag; reflect it in the interop env header.

7. **The production capture wiring has no test — say so.** `sec_trust_t` is not constructible in
   a unit test; add an explicit NOTE to the probe spec and task 1.5 (code inspection + interop
   gate), and have 1.5 verify `QUICTrustTests` still prove the three existing modes resolve
   unchanged after the exhaustive switch is edited.

8. **Extend the `api-reference` delta to "Error documentation"** (`ENOTSUP` on Linux for the
   probe; compile-time unavailability below the floor) and add `SMBQUICCertificateProbe` to the
   Swift-only / Objective-C sentence.

9. **The TOFU documentation must carry the first-contact caveat** as a spec'd requirement: an
   on-path attacker can present their own chain, so the SHA-256 must be confirmed out of band
   before persisting, and the anchor replaces the system roots for that connection.

### Observations (no action required)

- **O1 — D1 verified against the claim machinery.** Per-path cancel accounting is correct
  (fatal wait/failure/deadline → loss path cancels once and nils the driver so `close()` finds
  nothing; commit-to-start window → the handoff performs the single cancel and `close()` waits
  for it; `.ready` → the driver is *retained*, so the probe's `close()` is the one cancel — the
  `.ready` row is load-bearing). Repeated `.waiting(.tls)` is idempotent. The one-shot
  reservation is invisible because each probe builds a fresh transport.
- **O2 — `close()` is cancellation-safe**, so "always `await close()`, even on cancellation" is
  proven rather than hopeful.
- **O3 — D2's ordering argument is correct**; the `NSLock` supplies the cross-queue barrier.
- **O4 — the `api-reference` delta is a faithful full copy** of the existing requirement.
- **O5 — no `quic-transport-apple` or `architecture-docs` delta is needed.** Noted for a future
  cleanup change: `architecture-docs` is already stale (never mentions `QUICTransportApple`; still
  says the seam is not selectable through `SMB2Manager`).
- **O6 — `server:` over the issue's `host:` is right**; there is no *public* `server` precedent
  (`SMB2Manager(url:)`), so the doc comment must spell out the `host[:port]` grammar itself.
- **O7 — the 8 s default is right** and must be documented as independent of
  `SMBQUICConfiguration.connectTimeout`.
- **O8 — Linux ordering is `ENOTSUP` before `EINVAL`** (validation helper is Apple-only), matching
  `SMB2Manager.connectShare`; copy its `POSIXError(.init(ENOTSUP))` + `import Glibc` spelling.
- **O9 — the dead-code gate is satisfied**: every new symbol has a non-test call site.
- **O10 — rejecting the issue's `NWParameters` extraction is correct** (no second consumer).
- **O11 — D3's `SecTrustCopyCertificateChain` caveat is handled well**; add a unit case for a
  `nil` chain → `[]` (task 1.3).

### Conditions addressed (2026-08-29, after review)

All nine conditions are reflected in the artifacts:
1 → design D2 + task 1.4 (`@unchecked Sendable`, lock-guarded). 2 → design D1 (slot read after
`close()`; table keys on the thrown error; `.waiting(.fatal)`/`.failed` both land on `EPROTO`;
`close()` cancellation-safety and per-path cancel accounting recorded). 3 → probe spec
requirement reworded to "a started connection is cancelled exactly once" with a new
"Cancelled before start" scenario; task 2.1 case (h). 4 → design D4 split into
`validateQUICEndpoint(host:port:)` + `validatedQUICEndpoint(_:)`, Apple-only, `connect` parses
once; tasks 1.1/1.2. 5 → design D2 (truthful configuration, discarded `resolveTrust(.system)`,
scoping of the `quic-transport-apple` guarantee); probe spec sentence "unreachable from any
public configuration"; task 2.2. 6 → task 3.1 uses a new optional `SMB_QUIC_LEAF_DER`
(leaf equality; exactly-one-element only when leaf == CA); proposal Impact updated.
7 → probe spec NOTE + task 1.5 verification clause. 8 → `api-reference` delta gains the
"Error documentation" MODIFIED requirement and the Swift-only mention. 9 → `api-reference`
delta (requirement text + TOFU scenario), tasks 4.1/4.2, design Risks. O6/O7/O11 also folded
into design D5/D3 and tasks 2.2/1.3.
