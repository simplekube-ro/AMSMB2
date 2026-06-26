## Why

Today `SMB2Client` (`AMSMB2/Context.swift`) lets libsmb2 own the TCP socket end to end:
libsmb2 opens the connection, exposes the file descriptor via `smb2_get_fd()`, and
`SMB2Client` watches that fd with `DispatchSource` read/write sources (`SocketMonitor`),
calling `smb2_service()` on readiness. This is correct and well tested, but it hard-wires
the wire transport to libsmb2's built-in BSD socket. It blocks two things the project wants:

- **A real QUIC transport** (SMB-over-QUIC, the next milestone) — impossible while libsmb2
  owns a plain TCP socket and we only watch an fd.
- **Network.framework integration on Apple** — built-in TCP bypasses the OS's modern
  networking stack (multipath, fast-connect, on-demand VPN, App Transport Security posture,
  better cellular handling) that `NIOTransportServices` / Network.framework provide.

Our `simplekube-ro/libsmb2` fork already shipped an **external-transport API**
(`smb2_set_transport`, `struct smb2_external_transport`, `smb2_get_timeout`,
`smb2_service_timeout`) that lets a host application supply the bytes-on-the-wire layer.
This change introduces a Swift **transport seam** on top of that API so the wire layer
becomes pluggable, routes Apple TCP through `NIOTransportServices`, and leaves a clean
extension point for QUIC — without changing the public `SMB2Manager` API.

## What Changes

- **Introduce a Swift transport seam** (`SMBTransport` protocol + `SMBTransportKind` enum)
  that abstracts "carry SMB2 bytes over the network", independent of libsmb2 and NIO, so it
  is unit-testable in isolation and reusable by both TCP (this milestone) and QUIC (next).
- **Bridge libsmb2's synchronous C external-transport callbacks to the async seam.** This is
  a buffering shim: libsmb2's non-blocking `connect`/`send`/`recv`/`close` C callbacks are
  reconciled with an `async` Swift transport via inbound/outbound byte queues, with
  copy-at-the-boundary and `Unmanaged` userdata trampolines.
- **Add a no-fd servicing loop to `SMB2Client`.** When an external transport is selected,
  `smb2_get_fd()` returns `-1`, so the `DispatchSource` model cannot drive libsmb2. Servicing
  is instead driven by (a) an inbound-bytes-ready signal from the bridge and (b) timers bounded
  by `smb2_get_timeout()` / serviced by `smb2_service_timeout()`. The existing
  `CheckedContinuation` suspend/resume and task-cancellation semantics are preserved.
- **Implement `TCPTransportApple`** — a concrete `SMBTransport` backed by `NIOTransportServices`
  (SwiftNIO over Network.framework), Apple-only.
- **Add SwiftNIO + NIOTransportServices to the main `AMSMB2` target**, platform-guarded so the
  Linux build is unaffected.
- **Retarget the libsmb2 submodule** to `simplekube-ro/libsmb2` (which has the transport API)
  and verify the C symbols import into the Swift `SMB2` module.
- **Opt-in, then flip.** The seam ships behind an explicit `SMBTransportKind` selection first.
  Only after the full Samba integration suite passes through the NIO TCP transport with no
  observable behavior change do we make `TCPTransportApple` the default on Apple and delete the
  now-dead legacy `DispatchSource`/`SocketMonitor` path.
- **Apple-only seam; Linux keeps the legacy path.** `NIOTransportServices` is backed by
  Network.framework (Apple-only). Linux continues to use libsmb2's built-in libsmb2-owned TCP
  socket via the existing `DispatchSource` loop, behind `#if`.

### Non-Goals

- **No QUIC** in this milestone — the seam is designed so QUIC drops in later, but only TCP is
  implemented here.
- **No zero-copy.** Copy-at-the-boundary is mandatory for correctness; a zero-copy fast path is
  explicitly deferred.
- **No public API change.** `SMB2Manager`'s surface is unchanged; `SMBTransportKind` selection is
  the only new opt-in knob, and after the flip the default behavior is unchanged from the
  consumer's perspective.
- **No Linux NIO transport.** Linux is out of scope for the seam.

## Capabilities

### New Capabilities

- `transport-dependencies`: the libsmb2 fork's external-transport C symbols are importable from
  the Swift `SMB2` module, and SwiftNIO + NIOTransportServices are available (Apple-guarded) to
  the `AMSMB2` target.
- `transport-seam`: the `SMBTransport` protocol + `SMBTransportKind` enum (pure Swift, NIO-free
  and libsmb2-free), plus a `MockTransport` in-memory loopback double.
- `transport-bridge`: the sync-C ↔ async-Swift buffering bridge that wires libsmb2's
  `smb2_external_transport` callbacks to an `SMBTransport`, with copy-at-boundary,
  would-block-when-empty, and EOF-on-close semantics.
- `transport-servicing`: the opt-in no-fd servicing loop in `SMB2Client` driven by
  inbound-ready signals and `smb2_get_timeout`/`smb2_service_timeout` timers.
- `tcp-transport-apple`: `TCPTransportApple`, the `NIOTransportServices`-backed `SMBTransport`.
- `transport-rollout`: the opt-in-then-flip rollout — integration acceptance through the seam,
  the default flip on Apple, and removal of the legacy Apple `DispatchSource` path (Linux retained).

### Modified Capabilities

<!-- No existing OpenSpec specs to modify; this is a new subsystem. -->

## Impact

- **`.gitmodules` / submodule pin**: `Dependencies/libsmb2` retargeted to `simplekube-ro/libsmb2`,
  pinned to a commit with `smb2_set_transport`.
- **`AMSMB2/Parsers.swift`**: `Array<SMB2Share>.init(_ container:)` adapted to the fork's
  renamed srvsvc types (`srvsvc_SHARE_INFO_1_CONTAINER`, `EntriesRead`, `ses.ShareEnum.Level1`,
  `char *` pointer fields) because the pinned fork `master` carries a srvsvc DCE/RPC refactor
  alongside the transport API. Null NDR referents for `netname`/`remark` are guarded via
  `UnsafePointer<CChar>(bitPattern:)`. Two unit tests cover this guard.
- **`Package.swift`**: adds `swift-nio` (`NIOCore`, `NIOPosix` for tests if needed) and
  `swift-nio-transport-services` (`NIOTransportServices`) to the `AMSMB2` target.
- **New files** (Apple-guarded where noted): `SMBTransport.swift` (protocol + kind),
  `TransportBridge.swift` (C-callback bridge), `TCPTransportApple.swift` (`#if canImport(Network)`),
  plus `MockTransport` in the test target.
- **`AMSMB2/Context.swift`**: gains the opt-in no-fd servicing loop and transport selection at
  connect; after the flip, the Apple `SocketMonitor`/`DispatchSource` path is removed (kept under
  `#if` for Linux).
- **License records (`README.md`, `CLAUDE.md` as applicable)**: add Apache-2.0 notices for
  SwiftNIO + NIOTransportServices alongside the existing libsmb2 LGPL note.
- **Threading model**: unchanged for the default path until the flip; the seam reuses the same
  `eventLoopQueue`-serialized, continuation-based model.
