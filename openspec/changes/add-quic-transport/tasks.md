# Tasks: add-quic-transport

TDD applies throughout: each task starts by writing/updating the tests for its spec scenarios
(`swift test --disable-sandbox`), then the minimum implementation, then refactor.

## 1. Connection policy (pure logic first — fully unit-testable, no network)

- [x] 1.1 Table-driven tests for numeric-host classification (`isNumericHost(_:)`): rejected —
      `192.168.1.10`, `127.1`, `2130706433`, `0x7f000001`, `0177.0.0.1`, `fe80::1`, `[fe80::1]`
      (brackets stripped by parsing), `fe80::1%en0`, `::ffff:192.168.1.10`, empty host;
      accepted — `fs.example.com`, `localhost`, single-label, digit-containing names,
      trailing-dot FQDN. Then implement via `getaddrinfo` + `AI_NUMERICHOST` (design D4). The
      rejection table is acceptance criteria: if the platform classifier misses any required
      form on a supported platform, supplement `isNumericHost` with deterministic parsing for
      that form — never shrink the table (design D4). Plus
      the connect-path test asserting `.quic` throws `EINVAL` (specifically, not a connect-class
      error) before any transport is constructed, and a connect-path test with
      `trustPolicy: .insecureNoVerification` proving a numeric target still fails with `EINVAL`
      before any `NWConnection` is created — numeric rejection is independent of the TLS trust
      policy (`quic-connection-policy` spec)
- [x] 1.2 Tests for per-kind default port (445 tcp/automatic, 443 quic, explicit port honored);
      then the design-D4 plumbing restructure with the concrete signatures: add `defaultPort:`
      to `parseSeamEndpoint`, add `quicConfiguration:` to
      `connect(server:share:user:transportKind:)`, hoist parse + host validation into it
      (before transport construction and `bridge.connect()`), and change `connectWithBridge` to
      accept the resolved `(host, port)` and the kind's `selector:` so parsing happens exactly
      once (`transport-servicing` delta)
- [x] 1.3 Tests for kind dispatch and selector exactness: `.automatic` never yields QUIC;
      `.tcp`/`.automatic` install `SMB2_TRANSPORT_AUTO` and `.quic` installs
      `SMB2_TRANSPORT_QUIC` (design D9 — never implementation-defined); then update the `switch`
      at `Context.swift:1124` (transport construction stubbed until task 2). The
      below-availability-floor `ENOTSUP` branch is unreachable on CI hosts — verify by code
      inspection and mark the scenario manual, per the spec note
- [x] 1.4 Boundary tests then implementation for the QUIC connect-timeout contract (design
      D10): internal `normalizedQUICConnectTimeout(_:)` helper — `NaN`, `+infinity`,
      `-infinity`, `0`, and negative throw `EINVAL`; `> 3600` clamps to 3600; `3600` passes
      unclamped; sub-second values pass through; default 30 when `quicConfiguration == nil`.
      Wire the helper into the hoisted validation of task 1.2 (before transport construction,
      before any network activity) and assert independence from `SMB2Client.timeout` (zero/
      negative operation timeout still arms the QUIC deadline; `smb2_set_timeout` behavior
      unchanged)
- [x] 1.5 Tests then implementation for the D12 bridge-ownership handoff in
      `connectWithBridge` (`transport-servicing` delta, ADDED requirement): factor the
      lock-protected ownership state (`eagerConnecting → localOwned → installing → installed`,
      terminal `cancelled`/`finished`) into an internal type whose transition table —
      including the eager-completion reconciliation — is unit-tested directly, every
      transition and race deterministically, no real task-cancellation timing: reconciliation
      row A (success while `eagerConnecting` → `localOwned`, no close); row B
      (success while `cancelled` → consumed, close exactly once, `CancellationError`, no
      installation); row C (cancellation-shaped failure — `CancellationError` or
      `POSIXError(.ECANCELED)` — while `cancelled` → consumed, close exactly once, normalized
      to `CancellationError`); row D (any failure while `eagerConnecting` → `finished`, close
      exactly once, mapped original error rethrown — not `CancellationError`); race E
      (cancellation vs ordinary failure, both commit orders, documented precedence — the side
      whose transition committed first is caller-visible, exactly one close either way);
      cancel while `localOwned` (onCancel closes exactly once; the install block's failed
      `installing` claim makes no libsmb2 call and creates no resources); cancel racing the
      `installing` claim (exactly one winner; installed seam torn down via `teardownSeam()`).
      Restructure `connectWithBridge` so ONE outer `withTaskCancellationHandler` covers eager
      `bridge.connect` through seam installation, with the install block's first step —
      before `cbPtr`/`Unmanaged.passRetained(cb)`, before `makeExternalTransport()` and its
      `ext.userdata` retain, before any libsmb2 call — being the lock-protected `installing`
      claim; a failed claim resumes `CancellationError` and returns with nothing created and
      nothing to release; only a successful claim constructs `cbPtr`, validates the context,
      and installs, releasing on each failure path only what was created by that point.
      MockTransport-backed tests assert: TCP-shaped eager cancellation (transport throws
      `POSIXError(.ECANCELED)` internally) surfaces `CancellationError` to the caller;
      QUIC-shaped ready-after-cancel (transport connect succeeds despite outer cancellation)
      surfaces `CancellationError` with the bridge closed; ordinary eager MockTransport
      failure surfaces the mapped original error; cancellation racing ordinary failure
      resolves per the precedence rule in both orders; bridge `close()` called exactly once
      in every outcome; `transportBridge == nil`, no pending operation, and no
      `smb2_set_transport`/`smb2_connect_share_async` call after a cancellation or
      eager-failure win; and — via a test seam or structural assertion — a failed install
      claim invokes neither the callback-pointer factory nor `makeExternalTransport()`

## 2. SMBQUICConfiguration + QUICTransportApple

- [x] 2.1 Tests for `SMBQUICConfiguration`: `trustPolicy` defaults to `.system`,
      `connectTimeout` defaults to 30 (D10), `Sendable`/
      `Equatable`, conflicting trust (roots + insecure) is unrepresentable by construction, and
      the type is platform-neutral — no Security.framework types, DER `[Data]` anchors,
      `TimeInterval` timeout, compiles
      on Linux (verified in `make linuxtest`); then implement the struct
      (`quic-transport-apple` spec, D5)
- [x] 2.2 Implement `QUICTransportApple` skeleton: availability-gated final class
      (`@available(iOS 15, macOS 12, macCatalyst 15, tvOS 15, watchOS 8, visionOS 1, *)` —
      macCatalyst floor explicit), `NSLock`-guarded state, chunk-FIFO + single parked `receive()`
      waiter, idempotent `close()` that atomically records the local-close cause under the lock
      BEFORE calling `NWConnection.cancel()` (the D8 established-connection lifecycle:
      `ready → localClosing → closed` | `failed(error)`), resuming the parked waiter with empty `Data` (the
      local-close EOF signal — an empty-Data bridge teardown signal, not a peer-originated
      graceful EOF — matching `TCPTransportApple.signalClosed()`; `ENOTCONN` only for
      never-connected) — mirror
      `TCPTransportApple`'s shape (D3). Unit-test the state-machine paths that don't need a live
      server (never-connected `ENOTCONN`, double close, receive-after-close returns empty `Data`)
- [x] 2.3 Implement the D7 connect state machine with the **atomic outcome claim**: a
      lock-protected `claimConnectOutcome(_:)` transition that decides the winner AND assigns
      the side-effect duty in one critical section (losers perform no cancellation or cleanup;
      a winning `.ready` retains the connection for `send`/`receive` — the reference is not
      cleared on success; a winning cancel/deadline/failure/close cancels and releases the
      connection exactly once); explicit handling of
      `.setup`/`.preparing`/`.waiting` (non-terminal)/`.ready`/`.failed`/`.cancelled`;
      post-ready state events route to the D8 recorded-cause lifecycle (a `.cancelled` with a
      recorded local-close cause is the local-close signal; an unsolicited `.failed`, or
      `.cancelled` without a recorded local close, is abnormal loss), never to connect
      completion; `withTaskCancellationHandler` whose `onCancel` cancels the `NWConnection`
      only if it wins the claim; deterministic deadline from the validated `connectTimeout`
      (task 1.4) armed through the injectable scheduler; error contract (`CancellationError`
      for task cancel, `ECONNABORTED` for close-during-connect, `ETIMEDOUT` for deadline,
      mapped `POSIXError` for `.failed`). Build the D7 test seams first: internal
      `QUICConnectionDriver` (scripted state events, recorded `cancel()` calls) and
      `ConnectDeadlineScheduler` (fire-on-demand), injected via an internal initializer.
      Tests (per `quic-transport-apple` spec scenarios, all deterministic — no wall-clock, no
      TEST-NET dependence): cancellation before start; cancellation while `.waiting` (driver
      holds `.waiting`); ready-versus-cancel and failure-versus-cancel races asserting BOTH
      exactly-once continuation completion AND ownership/side effects (ready-wins → zero
      recorded `cancel()`, connection usable; cancel-wins → exactly one recorded `cancel()`,
      reference released); close while connecting; deadline expiry via scheduler fire (and
      deadline-after-ready is a no-op); successful connect keeps the connection and cancels the
      timer; post-ready failure surfaces via `receive()`; exactly-once resume under interleaved
      completions. Optionally add a non-gating TEST-NET-1 smoke test in the integration lane
      only
- [x] 2.4 Implement handshake parameter wiring: `NWParameters(quic:)` with ALPN `"smb"`,
      SNI = host, TLS 1.3 (D2); trust wiring from `SMBQUICConfiguration.trustPolicy` per the
      exact D5 fail-closed sequence: `.system` installs no verify block;
      `.customRoots` — (1) convert every DER anchor via `SecCertificateCreateWithData` before
      `NWConnection` creation, throwing `EINVAL` on invalid DER and on `.customRoots([])`;
      (2) in the verify block obtain the `SecTrust` from the callback's `sec_trust_t` via
      `sec_trust_copy_ref` (NOT `sec_protocol_metadata_copy_sec_trust`); (3) apply
      `SecPolicyCreateSSL(true, host)` via `SecTrustSetPolicies`; (4) install anchors via
      `SecTrustSetAnchorCertificates` + `SecTrustSetAnchorCertificatesOnly(true)`; (5) check
      every `OSStatus`, rejecting on any failure; (6) evaluate via
      `SecTrustEvaluateWithError`; (7) complete exactly once on every path.
      `.insecureNoVerification` skips chain/hostname checks only. Factor steps 3–6 into the
      internal `evaluateCustomRootsTrust(_:host:anchors:)` helper (D5). Unit tests:
      no-verify-block-under-`.system`, invalid-DER `EINVAL`, empty-`.customRoots([])` `EINVAL`,
      and the evaluation helper against `SecTrust` objects built with
      `SecTrustCreateWithCertificates` (custom root w/ correct and wrong hostname, system-root
      chain rejected under `.customRoots`, self-signed leaf as own anchor) — no live
      handshake needed; the live end-to-end trust matrix (system trust w/ correct host, invalid
      cert rejected, custom root cases over a real handshake, insecure mode) lands in the
      interop matrix (task 4.3)
- [x] 2.5 Implement `send(_:)`/`receive()` over the single bidirectional stream with re-arming
      `NWConnection.receive`, plus the D8 established-connection lifecycle with recorded
      causes (`ready → localClosing → closed` | `failed(error)`): peer-originated graceful EOF
      (empty `Data` from a remote close); local close (`close()` records `localClosing` under
      the lock before `NWConnection.cancel()`; the resulting `.cancelled` event is a no-op
      acknowledgment, never abnormal loss); abnormal loss (unsolicited post-ready `.failed`,
      or `.cancelled` without a recorded local-close cause → parked/next `receive()` throws
      `POSIXError`). Deterministic tests through the injected driver's post-ready event
      delivery (design D7 seams): local close followed by `.cancelled`; `.cancelled` racing
      local close (one deterministic winner under the lock; a recorded local-close result is
      never overwritten); unsolicited `.failed` and unsolicited `.cancelled` → abnormal loss;
      receive already parked at teardown and `receive()` called after teardown; exactly-once
      waiter resumption and exactly-once resource cleanup
- [x] 2.6 Wire `.quic` in the `Context.swift` kind dispatch to construct
      `QUICTransportApple(configuration:connectTimeout:)` (replacing the task-1.3 stub) with the
      `SMB2_TRANSPORT_QUIC` selector; run the full seam unit suite (bridge/servicing tests must
      stay green)

## 3. SMB2Manager public API

- [x] 3.1 Tests then implementation for `SMB2Manager.transportKind` (default `.automatic`) and
      `quicConfiguration`: backing storage guarded by `connectLock` via synchronous accessors;
      snapshot semantics per design D6 — `connect(shareName:encrypted:)` (`AMSMB2.swift:1501`)
      takes the `transportSnapshot()` under `connectLock` before any suspension and passes it to
      `SMB2Client.connect(...transportKind:quicConfiguration:)`. Tests: snapshot immutability
      (mutating settings mid-connect does not affect the in-flight attempt), settings change
      while connected leaves the connection untouched and applies on next connect
- [x] 3.2 Tests then implementation for serialization AND copying: `transportKind` round-trips
      through `NSSecureCoding`/`Codable` via a private string mapping (no public
      `RawRepresentable` added to `SMBTransportKind`), old archives decode to `.automatic`,
      `quicConfiguration` never serialized (decoded `.quic` manager gets system-trust default);
      `copy(with:)` preserves value snapshots of BOTH `transportKind` and `quicConfiguration`
      (never a silent reversion to `.automatic`), and the copy is unaffected by later mutation
      of the original
- [x] 3.3 Implement the D11 Swift-only Objective-C decision: verify no `@nonobjc` is needed
      (SMB2Manager is not `@objcMembers`; the new types are not ObjC-representable, so `@objc`
      inference cannot apply) and add a compile-level check that the generated Objective-C
      interface (`-emit-objc-header` output or equivalent) contains none of `transportKind`,
      `quicConfiguration`, `SMBQUICConfiguration`, `QUICTransportApple`, while every
      pre-existing `@objc(...)` selector in ObjCCompat.swift is unchanged (existing ObjC compat
      surface stays source-compatible); document the Swift-shim guidance for ObjC apps in
      task 5.1's API.md update
- [x] 3.4 Linux routing tests (run under `make linuxtest`, per design D6): the manager takes
      the same snapshot before suspension on Linux; `.quic` → `POSIXError(.ENOTSUP)` before any
      transport construction or network activity (no silent downgrade); `.tcp` and `.automatic`
      invoke the legacy `connect(server:share:user:)` path unchanged; compile-level assertion
      that no Network/Security-dependent QUIC type participates in the Linux build

## 4. Interop verification (the release gate)

- [x] 4.1 Interop rig: **stood up and Samba↔Samba-verified 2026-07-24** on
      `ubuntu-brix.kaveman.intra` — DKMS `quic.ko` (lxin/quic) on the host, Samba 4.23.6 with
      `server smb transports = +quic` in Docker (image `samba-quic:4.23.6`; rig, lab CA, and
      README in `~/smb-quic-rig/` on the box; test share `//ubuntu-brix.kaveman.intra/share`,
      user smbtest). Remaining: port the rig README (incl. the libquic-version, TLS-key-uid,
      and silent-QUIC-drop traps) into `docs/` as the repeatable interop procedure (WS2025
      target deferred — see design Risks/Open Questions)
- [x] 4.2 First-contact gate: QUIC handshake + NEGOTIATE round-trip; **verify the 4-byte framing
      assumption on the wire** (design D2 must-verify). If framing differs, stop and fix in the
      libsmb2 fork seam before proceeding
- [x] 4.3 Interop matrix: NTLM auth, share list, directory listing, large read/write,
      cancel/timeout mid-transfer, numeric-target rejection, QUIC-only failure mode (server
      without QUIC), best-effort local disconnect + observed server-side session teardown and
      peer-originated graceful EOF (design D8 — NOT a guaranteed-DISCONNECT-delivery check), and
      the live TLS trust matrix from task 2.4: system trust with correct host, invalid/untrusted
      certificate rejected, custom root with correct hostname, custom root with wrong hostname
      (wrong-hostname: manual-only / unit-proven in `evaluateCustomRootsTrust` — no resolvable
      non-SAN name for the rig without editing system DNS),
      system-root exclusion under `.customRoots`, insecure mode. Against the 4.1 rig: the
      custom-root anchor is the rig's lab CA (`~/smb-quic-rig/tls/ca.crt` on ubuntu-brix,
      DER-converted) — the server cert chains only to it, so it also exercises system-trust
      rejection; correct hostname = `ubuntu-brix.kaveman.intra` (cert SANs include
      `ubuntu-brix` and `localhost` for the wrong/alternate-hostname cases)
- [x] 4.4 Fold interop findings back: idle-timeout/keepalive tuning only if 4.3 shows premature
      teardown; update design.md with what was actually observed

## 5. Documentation and archive

- [x] 5.1 Update `docs/API.md` per the `api-reference` delta (new types incl.
      `SMBQUICConfiguration.TrustPolicy` and `connectTimeout` — default 30 s, `EINVAL`/clamping
      contract, independence from `SMB2Manager.timeout` — per-platform availability floors
      incl. macCatalyst 15 and Linux `ENOTSUP`, QUIC policy (non-numeric hostnames only) and
      error conditions incl. `ETIMEDOUT`/`ECONNABORTED`, snapshot/copy/serialization semantics,
      the Swift-only ObjC posture with the Swift-shim guidance (D11), best-effort disconnect,
      caller-side fallback pattern)
- [x] 5.2 Update `docs/ARCHITECTURE.md` (QUIC conformer beside TCP in the seam diagram) and
      README (opt-in usage example with the security caveats)
- [x] 5.3 Pre-archive sweep: dead-code check (every new symbol has a call site outside its
      file), SwiftFormat, full `swift test --disable-sandbox` green, `make linuxtest` green
      (platform-neutral configuration compiles and `.quic` → `ENOTSUP` on Linux), macCatalyst
      build check (`xcodebuild build -destination 'generic/platform=macOS,variant=Mac Catalyst'`
      or equivalent) plus inspection that QUIC availability annotations name macCatalyst 15.
      Also run the authoritative D11 header grep: generate the Objective-C interface
      (`swiftc -emit-objc-header` / the `-Swift.h` equivalent) and assert `transportKind`,
      `quicConfiguration`, `SMBQUICConfiguration`, and `QUICTransportApple` are all absent — the
      runtime-introspection unit test (task 3.3) cannot catch an accidental `@objcMembers`
      addition, so the generated-header grep remains the compile-level check of record per D11
- [ ] 5.4 Ensure artifacts reflect what shipped, close AMSMB2 #29 / RandomPlayer #346, archive
      via `/opsx:archive`
