# Tasks

Each task group maps 1:1 to a milestone issue. TDD is mandatory for code tasks (write the failing
test from the linked spec scenario first); config/manifest tasks are TDD-exempt per CLAUDE.md.

## T1 — Retarget libsmb2 submodule to the fork (#20) [transport-dependencies]

- [x] 1.1 Update `.gitmodules`: set `Dependencies/libsmb2` url to `https://github.com/simplekube-ro/libsmb2`
- [x] 1.2 `git submodule sync` + `git submodule update --init`; check out the fork commit that contains `smb2_set_transport` (fork `master` head with the transport API); pin the exact SHA in the AMSMB2 commit
- [x] 1.3 Verify `swift build --disable-sandbox` and `swift test --disable-sandbox` pass (unit tests; integration skips without a server). **Note:** The fork's `master` (944f7d1) carries a srvsvc DCE/RPC refactor beyond the transport API — upstream symbols `srvsvc_SHARE_INFO_1_carray`, `max_count`, `ses.ShareInfo.Level1.Buffer`, and `.utf8` on fixed char arrays are replaced by `srvsvc_SHARE_INFO_1_CONTAINER`, `EntriesRead`, `ses.ShareEnum.Level1`, and `char *` pointer fields. This required adapting `AMSMB2/Parsers.swift` (`Array<SMB2Share>.init(_ container:)`) to the renamed types and to guard null NDR referents via `UnsafePointer<CChar>(bitPattern:)`. The adaptation is the only required Swift source change; two regression tests cover the null-pointer guard.
- [x] 1.4 Update `CLAUDE.md` / `README.md` prerequisite/submodule-URL notes if they reference the upstream URL

## T2 — Expose transport C symbols to the Swift SMB2 module (#21) [transport-dependencies]

- [x] 2.1 Verify `smb2_set_transport`, `smb2_external_transport`, `SMB2_TRANSPORT_TCP/QUIC/AUTO`, `smb2_get_timeout`, `smb2_service_timeout` import from `import SMB2`; fix the C target modulemap / umbrella header / include settings if any symbol is missing
- [x] 2.2 (TDD) Add a Swift smoke test in the test target (`import SMB2`) referencing all five symbols + every `smb2_external_transport` field, and asserting `SMB2_TRANSPORT_TCP==0`, `QUIC==1`, `AUTO==2`
- [x] 2.3 Verify `swift build --disable-sandbox` and `swift test --disable-sandbox` pass

## T3 — Add SwiftNIO + NIOTransportServices to Package.swift, Apple-guarded (#22) [transport-dependencies]

- [x] 3.1 Add package deps: `swift-nio` (`NIOCore`; `NIOPosix` only if a test needs it) and `swift-nio-transport-services` (`NIOTransportServices`), pinned to current stable majors
- [x] 3.2 Add them to the `AMSMB2` target's dependency list
- [x] 3.3 Ensure all NIO imports/usage are platform-guarded (`#if canImport(Network)`) so Linux builds with no NIO transport compiled in
- [x] 3.4 Record Apache-2.0 license notices for SwiftNIO + NIOTransportServices alongside the libsmb2 LGPL note (`README.md` / `CLAUDE.md` as applicable)
- [x] 3.5 Verify `swift build --disable-sandbox` succeeds on Apple; confirm the Linux build path stays compilable
  - Resolved: swift-nio 2.101.2, swift-nio-transport-services 1.28.0
  - `swift build --disable-sandbox`: Build complete (21.4 s)
  - `swift test --disable-sandbox`: 94 tests, 0 failures (44 integration tests skipped — no server)
  - `NIODependencyTests` (2 tests) exercised `ByteBuffer` and `NIOTSEventLoopGroup` successfully
  - Linux build path: not executed (no Linux toolchain in this environment); confirmed by `.when(platforms:)` guards in Package.swift that exclude NIOCore + NIOTransportServices from Linux targets, matching the `#if canImport(Network)` source guards in `NIODependencyTests.swift`

## T4 — Define SMBTransport protocol + SMBTransportKind enum (+ mock) (#23) [transport-seam]

- [x] 4.1 (TDD) Write the protocol-conformance + `MockTransport` round-trip/EOF/connect-failure tests first
- [x] 4.2 Define `public protocol SMBTransport: Sendable` with `connect(host:port:)`, `send(_ bytes: Data)`, `receive() -> Data`, `close()` — NIO-free and libsmb2-free; buffer type is `Data` (design D2)
- [x] 4.3 Define `public enum SMBTransportKind: Sendable { case tcp, quic, automatic }`
- [x] 4.4 Provide `MockTransport` (in-memory loopback) in the test target with failure/never-reply/graceful-EOF injection
- [x] 4.5 Verify zero Swift 6 strict-concurrency warnings; tests pass
  - `swift build --disable-sandbox`: Build complete, 0 warnings in new files
  - `swift test --disable-sandbox`: 103 tests, 9 new (SMBTransportTests), 44 skipped (integration — no server), 0 failures
  - Linux build path: not executed (no Linux toolchain); `SMBTransport.swift` uses only `Foundation` — no `#if` guard needed; it compiles on Linux as-is

## T5 — Bridge libsmb2 external-transport callbacks to async SMBTransport (#24) [transport-bridge]

- [ ] 5.1 (TDD) Write bridge tests against `MockTransport`: round-trip through C `send`/`recv`, copy-at-boundary (overwrite source buffer after `send` returns), would-block-when-empty, EOF-on-close, clean teardown on cancel
- [ ] 5.2 Implement the bridge type: synchronous lock-guarded inbound/outbound `Data` FIFOs + the `SMBTransport` instance (design D3/D5)
- [ ] 5.3 Implement the four C trampolines (`connect`/`send`/`recv`/`close`) populating `smb2_external_transport`; recover the bridge from `userdata` via `Unmanaged` (`passRetained` once, balanced on teardown)
- [ ] 5.4 Implement copy-at-the-boundary in `send`/`recv` — synchronous unsafe copy, no `await` inside the closure (design D4)
- [ ] 5.5 Implement outbound-drain and inbound-fill pump `Task`s with would-block/EOF/error semantics and correct cancellation/teardown
- [ ] 5.6 Verify zero Swift 6 strict-concurrency warnings; tests pass

## T6 — External-transport servicing loop in SMB2Client, opt-in (#25) [transport-servicing]

- [ ] 6.1 (TDD) Write servicing tests: full mock exchange resumes the continuation (no hang); timer-driven timeout via a never-replying mock; legacy path unchanged; cancellation tears down cleanly
- [ ] 6.2 Add opt-in `SMBTransportKind` to `SMB2Client.connect`; when selected (Apple), build `TCPTransportApple`, wrap in the bridge, call `smb2_set_transport(ctx, AUTO, ext)` before `smb2_connect_share_async`
- [ ] 6.3 Enforce the naming trap: use `SMB2_TRANSPORT_QUIC`/`AUTO` (never `TCP`) for the seam; add a comment + assertion that `smb2_get_fd(context) == -1` under the seam
- [ ] 6.4 Implement the no-fd servicing loop on `eventLoopQueue`: inbound-ready signal → `smb2_service` with `revents` from `smb2_which_events`; flush `POLLOUT` after queueing operations (replaces `SocketMonitor.activateWriteSourceIfNeeded`)
- [ ] 6.5 Implement timer servicing: `smb2_get_timeout` → `eventLoopQueue.asyncAfter` → `smb2_service_timeout`, rescheduled per pass and cancelled on teardown
- [ ] 6.6 Implement the seam connect path (no `poll(fd)`; drive via bridge readiness) reusing the existing `CBData`/continuation/`isAbandoned`/`withTaskCancellationHandler` machinery
- [ ] 6.7 Keep the default (no kind) path byte-for-byte legacy; verify existing unit tests green
- [ ] 6.8 Verify zero Swift 6 strict-concurrency warnings; tests pass

## T7 — Implement TCPTransportApple on NIOTransportServices (#26) [tcp-transport-apple]

- [ ] 7.1 (TDD) Write what's feasible without a server: connect-failure and cancellation paths (e.g. `EmbeddedChannel`/loopback), inbound buffering / incremental drain, graceful-EOF
- [ ] 7.2 Implement `TCPTransportApple: SMBTransport` with `NIOTSConnectionBootstrap` / Network.framework-backed channel; `#if canImport(Network)`
- [ ] 7.3 Implement `connect`/`send`/`receive`/`close`; channel handler buffers inbound bytes for incremental `recv` drain; convert `Data`↔`ByteBuffer` internally (design D2)
- [ ] 7.4 Map connect-failure and cancellation to `POSIXError(.CODE)`; ensure no channel leak on cancel
- [ ] 7.5 Verify Apple build succeeds, Linux build unaffected, zero Swift 6 concurrency warnings; tests pass

## T8 — Full Samba integration suite through the NIO TCP transport (#27) [transport-rollout]

- [ ] 8.1 Add an env toggle (alongside `SMB_SERVER`) so `SMBIntegrationTestCase`-derived tests connect via the seam (`SMBTransportKind`)
- [ ] 8.2 Exercise the acceptance matrix through the seam: connect, NTLM auth, directory listing, large read, large write, cancel/timeout (heed CLAUDE.md gotchas: no pipelined writes with stream I/O; `contents(atPath:)` overload disambiguation; `import SMB2` for C symbols)
- [ ] 8.3 Run the suite both ways (legacy + seam) and confirm identical outcomes / no observable behavior difference
- [ ] 8.4 Add a CI leg running the seam integration path (Docker Samba via `make integrationtest` / `scripts/test-integration.sh`)

## T9 — Flip default on Apple + remove legacy DispatchSource path (#28) [transport-rollout]

- [ ] 9.1 Precondition: T8 (#27) green — only flip after acceptance passes
- [ ] 9.2 Make `TCPTransportApple` the Apple default (no opt-in); map `automatic` → seam on Apple
- [ ] 9.3 Remove the now-dead Apple legacy socket code (`SocketMonitor`, `DispatchSource` read/write sources, built-in-socket fd servicing) in this task — no orphaned helpers (CLAUDE.md dead-code rule)
- [ ] 9.4 Keep the legacy libsmb2-owned TCP path compiled and functional on Linux via `#if`
- [ ] 9.5 Re-run full unit + integration suites on Apple (seam by default) and the Linux build/test path; verify all green
