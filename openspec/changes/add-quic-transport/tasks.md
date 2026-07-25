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
      graceful EOF — matching `TCPTransportApple.signalClosed()`; `receive()` after `close()`
      returns empty `Data`, while `send(_:)` throws `ENOTCONN` whenever no usable connection
      exists, including after `close()`, and `receive()` throws `ENOTCONN` only when never
      connected — the same asymmetry as `TCPTransportApple`) — mirror
      `TCPTransportApple`'s shape (D3). Unit-test the state-machine paths that don't need a live
      server (never-connected `ENOTCONN` on both directions, double close,
      receive-after-close returns empty `Data`, send-after-close throws `ENOTCONN`)
- [x] 2.3 Implement the D7 connect state machine with the **atomic outcome claim**: a
      lock-protected `resolveConnect(_:)` transition (with the lock-held helper
      `consumeLossClaimLocked(_:error:) -> LossDuty?`) that decides the winner AND assigns
      the side-effect duty in one critical section, with the effects themselves performed
      outside the lock by the assigned party (losers perform no cancellation or cleanup;
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
- [x] 2.6 Wire `.quic` in the `Context.swift` kind dispatch to construct the throwing
      `QUICTransportApple(configuration:)` (replacing the task-1.3 stub; the initializer
      derives, validates, and normalizes the connect timeout from
      `configuration.connectTimeout` — see task 6.2) with the
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

## 6. Adversarial-review fixes (post-implementation)

- [x] 6.1 P1 — atomic start/loss handoff: a loser that wins the connect claim in the
      commit-to-start window parks its outcome (`pendingLoss`); the starting path finishes it
      after `driver.start()` returns (cancel exactly once, then resume), so the driver is never
      cancelled before its start side effect and never started after a losing teardown.
      Regression-tested with a gated-start driver for close(), task cancellation, and deadline
      expiry; pre-commit suppression covered by the existing `ImmediateFireScheduler` and
      gated-factory tests
- [x] 6.2 P2 — public `QUICTransportApple(configuration:)` (now `throws`) derives the connect
      deadline from `configuration.connectTimeout` via `normalizedQUICConnectTimeout`, removing
      the separate unvalidated `connectTimeout:` argument (single source of truth; direct
      construction cannot bypass EINVAL/clamping); tested through the public initializer
- [x] 6.3 P2 — `NWConnectionQUICDriver` accepts only ports 1...65535; out-of-range ports
      (0, negative, > 65535) produce `POSIXError(.EINVAL)` with no `NWConnection` (65536 no
      longer truncates to UDP/0); boundary-tested for 0, -1, 1, 65535, 65536, 1 << 20 and via
      the public transport path
- [x] 6.4 P3 — refreshed stale `.quic` wording in `SMBTransport.swift` and `docs/API.md`;
      `quic-transport-apple` / `quic-connection-policy` / `api-reference` specs updated for the
      D7 start/loss handoff, the throwing `QUICTransportApple(configuration:)` initializer, and
      the 1...65535 port contract
- [x] 6.5 P1 — artifact/comment truth pass after the second fresh review: restated D7 cleanup
      duty as *assigned by the claim, executed by the start handoff* (design.md, proposal.md,
      and the `resolveConnect` doc comment no longer claim the winner always cancels the
      deadline); added the port-range decision and its post-construction placement rationale to
      design D4; replaced the phantom `claimConnectOutcome`/`ClaimedDuty` names with the shipped
      `resolveConnect(_:)` / `consumeLossClaimLocked(_:error:) -> LossDuty?` in design.md,
      tasks.md, and `Context.swift`; made the `ENOTCONN` requirement match the shipped
      (TCP-compatible) contract and covered `send()` after `close()` with a test; removed the
      stale "not yet constructed in this batch" / "later batch" / "Batch-A stub" comments; and
      reconciled the proposal Impact file list with the files this change actually adds
- [x] 6.6 P1 — second truth pass after the third fresh review, which found two surviving
      instances of the same two defect classes that 6.5 fixed only in the sections it named:
      the `quic-transport-apple` "No double resume" scenario still said "the winning path alone
      performs cleanup" (now restated as claim-assigns / handoff-executes), and design D3 plus
      the `receive()` source comment still said `ENOTCONN` was "reserved for the
      never-connected case" (now stated as the transport's no-usable-connection error, with
      `receive()`-after-local-close the single exemption). Also corrected the same
      winner-performs-cleanup phrasing in `docs/ARCHITECTURE.md`, narrowed this change's own
      "matches `TCPTransportApple` exactly" post-close claim to the signals actually shared and
      recorded the buffered-drain ordering divergence, documented the then-accepted cost of the
      parked commit-to-start window — `close()` could return before the start fired — (that
      allowance was later judged a violation of `SMBTransport.close()`'s released-on-return
      contract and replaced by the close-waiter handoff in 7.1), and listed
      the three modified test files in the proposal Impact. Lesson recorded: sweep for the
      offending *phrases* repo-wide, not only the sections a review names
- [x] 6.7 P1 — cleared both conditions attached to the APPROVED WITH CONDITIONS verdict. The
      same over-claim class had survived one level below the requirement prose, in two
      normative WHEN/THEN scenarios of the `quic-transport-apple` spec: "Deadline expiry" and
      "Close while connecting" both asserted the `NWConnection` "is cancelled exactly once",
      which is false when the loss wins at `startPhase == .notStarted` — and, for the deadline
      case, is directly falsified by the shipped passing test
      `testDeadlineWinsBeforeStartSuppressesDriverStart`, which asserts `cancelCount == 0`.
      Both scenarios now scope the cancel to the already-started case and state the
      pre-commit suppression explicitly, so no false acceptance criterion reaches
      `openspec/specs/` on archive. Verified the neighbouring race scenarios do NOT need the
      same scoping: their premises (`.ready`/`.failed`/`.waiting` delivered by the driver)
      imply a started driver. Also recorded the full review history in proposal.md — the
      first remediation-pass verdict is now preserved as its own superseded section rather
      than only summarised, and the review ordinals were corrected
- [x] 6.8 Conditions confirmed cleared by the same reviewer against the live worktree; verdict
      upgraded to **APPROVED** and recorded in proposal.md, with the conditions-era text kept as
      superseded history so the gate sees in-file evidence that the conditions were satisfied.
      Took the reviewer's optional editorial suggestion: both corrected scenarios now name the
      "Loss in the commit-to-start window" scenario explicitly, so the three-phase partition is
      stated rather than inferred (name-based reference, so it survives reordering). Recorded in
      the verdict, for future scenario authors: the neighbouring race scenarios are correct
      because a pre-start `emit` is a no-op (`onState` is assigned only inside `start()`) AND
      because they assert duty *accounting* (one cancel, one resume) rather than attributing the
      cancel to a party — accounting is phase-invariant once the driver is started, attribution
      is not

## 7. Close-completion truth, overflow safety, and executor-safe race tests (fourth review pass)

- [x] 7.1 P1 — `close()` completion made truthful: the previously "accepted cost" of the parked
      commit-to-start window (`close()` could return before the start fired) violated
      `SMBTransport.close()`'s released-on-return promise and was replaced with close waiters —
      parking a loss sets `teardownPending` under the lock, every `close()` call (first,
      repeated, or concurrent) that observes it parks a continuation in `closeWaiters`, and the
      post-start handoff resumes those waiters only after cancelling the started driver and
      resuming the connect continuation. Deterministic regression tests prove: close does not
      complete while the committed start is gated; releasing the start yields exactly
      `start → cancel`; `close()` completes only after the cancel (event-ordered
      `close-returned`); connect throws `ECONNABORTED` exactly once; two concurrent closes wait
      for the same teardown with one cancel; and `close()` waits even when task cancellation
      (not close) parked the loss. Task cancellation and deadline expiry keep their existing
      rule — the continuation is not resumed until the committed driver has been cancelled
- [x] 7.2 P2 — overflow-safe endpoint port parsing: `parseLeadingPort` stops accumulating once
      the value already exceeds 65535 (no later digit can make it valid; intermediate bounded
      at 655,359), so an arbitrarily long digit string never traps; the `.quic` branch rejects
      explicit ports outside 1...65535 with `EINVAL` at endpoint validation, before any
      transport is constructed or the `NWConnection` driver factory is reached (the driver
      keeps its own fail-closed check for directly constructed transports). Endpoint regression
      tests cover a 300-digit port (plain and bracketed host form), 0, and 65536; parser
      boundary tests preserve 65535 and 65536 exactly; TCP parsing is unchanged for every
      in-range port
- [x] 7.3 P2 — executor-safe deterministic race tests: `driver.start()` and the post-start
      handoff now run on a dedicated serial start queue (`org.amsmb2.quic.start`), so
      `GatedStartDriver`'s park occupies a GCD worker, never a Swift cooperative-pool thread;
      its wait is bounded (10 s) and records a `start-timeout` diagnostic event so broken
      coordination fails visibly instead of hanging; the cancellation-before-start test cancels
      the current task from inside the driver factory (no semaphore, no parking). The full QUIC
      transport suite verified green under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`
- [x] 7.4 Unrelated `scripts/test-integration.sh` teardown-suppression hunk (committed as
      0f7ea0e during an earlier remediation sequence) restored to the pre-change content as an
      unstaged worktree edit; disposition of the already-pushed commit is left to the maintainer
- [x] 7.5 Artifacts reconciled with the shipped behavior: design D7 (close-waiter ownership
      invariant and the dedicated start queue, replacing the "accepted cost" paragraph), design
      D4 (layered port validation with the hoisted endpoint check), `quic-transport-apple`
      (close-completion requirement, commit-to-start and concurrent-close scenarios),
      `quic-connection-policy` (overflow-never-traps scenario, endpoint-level rejection),
      `docs/ARCHITECTURE.md`, proposal.md, and source comments; the stale APPROVED verdict
      marked superseded pending a fresh review

## 8. State-machine ownership repair (fifth review pass)

- [x] 8.1 P1 — one-shot connect ownership: `connect` atomically reserves the instance's single
      attempt (`.idle → .reserved` under the lock, before trust resolution or driver
      construction); rejected calls fail promptly and construct nothing — `EALREADY` while the
      attempt is in flight or after a failed attempt (retry unsupported: one instance per
      connection lifetime), `EISCONN` after `.ready`, `ECONNABORTED` after `close()` (checked
      first) — and can never overwrite the owning attempt's continuation, driver, deadline, or
      start phase. Close/cancellation racing the reservation-to-store phase abort the attempt
      at the store (a `cancelRequested` flag bridges task cancellation onto the start queue).
      Deterministic tests: concurrent double connect (owner completes, loser prompt-fails),
      connect after ready (EISCONN, original driver still usable), connect racing the
      commit-to-start gap (no overwrite, one start), connect after close (factory never
      invoked), retry-after-failure (EALREADY, no second driver), exactly-once start and
      terminal resolution throughout; all joins bounded so a regression fails instead of
      hanging
- [x] 8.2 P1 — general close lifecycle (`open → closing → closed`): the first `close()` caller
      atomically becomes the teardown owner; it performs the resource teardown on a dedicated
      teardown queue (`org.amsmb2.quic.teardown`), waits for in-flight connect work, and only
      then publishes `.closed` and resumes every parked caller — so EVERY concurrent close
      caller, in every teardown phase (established teardown, pre-commit abort, parked
      commit-to-start loss, cancellation-parked loss), observes completed teardown; only a
      close after full completion returns immediately. Replaces the narrow
      `isClosed`/`teardownPending` pair; the dead `.localClosing` lifecycle case (review O2)
      removed. Deterministic tests: gated-cancel established teardown with two concurrent
      closes (neither returns early, one cancel), gated-arming pre-commit abort with two
      concurrent closes, existing parked-loss and cancellation-parked-loss gap tests, prompt
      no-op after completed close
- [x] 8.3 P2 — late-armed deadline cancelled: the connect attempt re-checks the claim after
      `deadline.schedule` returns and cancels the (idempotent) scheduler again when the claim
      was consumed while the timer was arming — no timer survives a terminal connect outcome or
      a completed close; the "bounded self-expiry is benign" scoping (review O1) is retracted.
      Deterministic tests: a scheduler that fires the loss synchronously before recording
      itself armed (final state unarmed, one resolution), task cancellation during a gated
      `schedule()` (late-armed timer cancelled after release), close during a gated
      `schedule()` (covered by the pre-commit-abort close test)
- [x] 8.4 P2 — close waits for the in-flight `start()` tail independent of parked losses:
      `connectWorkInFlight` spans the whole attempt on the start queue (store → deadline arming
      → commit → `start()` → handoff) and the close owner parks on it before finalizing — the
      ready-mid-start case (`.ready` wins while `start()` has not returned) now cancels the
      ready driver immediately but returns only after the tail finishes; the prior "needs no
      wait" scoping is retracted. Deterministic test: a driver that emits `.ready` inside
      `start()` then parks — close does not return while gated, releases yield
      `start-entered → cancel → start-returned → close-returned` with exhaustive final events
- [x] 8.5 Whole-attempt executor discipline: the connect attempt after the continuation store
      runs entirely on the dedicated start queue (never a cooperative thread), which is also
      what makes the pre-commit and store-to-schedule windows deterministically testable with
      bounded GCD-parked doubles; `QUICConnectionDriver` is `Sendable` (conformers lock their
      state); QUIC transport suite green with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`
- [x] 8.6 Artifacts reconciled: design D7 (one-shot reservation, close lifecycle, in-flight
      work span, late-armed re-check, retracted self-expiry/ready-mid-start scoping), design
      D8 (`ready → closed` lifecycle), `quic-transport-apple` spec (one-shot requirement +
      scenarios; close-lifecycle requirement replacing "second call is a no-op"; late-armed
      deadline scenario; ready-mid-start scenario), `SMBTransport` protocol docs (single
      connection lifetime per instance; close released-on-return for every caller),
      `docs/ARCHITECTURE.md`, source comments, proposal.md; the round-8 APPROVED verdict marked
      superseded pending a fresh project-architect review
