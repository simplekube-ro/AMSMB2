# transport-dependencies Specification

## Purpose
Establish the dependency foundation for the pluggable transport: pin the `Dependencies/libsmb2` submodule to a `simplekube-ro/libsmb2` commit that exposes the external-transport C API (`smb2_set_transport`, `struct smb2_external_transport`, the `SMB2_TRANSPORT_*` constants, `smb2_get_timeout`, `smb2_service_timeout`), make those symbols importable from the Swift `SMB2` module, and add SwiftNIO and NIOTransportServices to the AMSMB2 target under Apple guards while keeping the Linux build NIO-free. Third-party Apache-2.0 notices SHALL be recorded alongside the existing libsmb2 LGPL note.

## Requirements

### Requirement: libsmb2 submodule provides the external-transport API

The `Dependencies/libsmb2` submodule SHALL point at `simplekube-ro/libsmb2` and be pinned to a
commit whose public umbrella header declares `smb2_set_transport`,
`struct smb2_external_transport`, `SMB2_TRANSPORT_TCP/QUIC/AUTO`, `smb2_get_timeout`, and
`smb2_service_timeout`. A fresh clone plus `git submodule update --init` plus
`swift build --disable-sandbox` SHALL succeed. The submodule was pinned to `944f7d1` for T1; T6
(#25) advanced the pointer to a descendant commit `112803c` ("fix: ext_close once-semantics to
prevent double-close use-after-free"), which the Swift external-transport close trampoline relies
on for a single `takeRetainedValue`. References to `944f7d1` below describe the original T1 srvsvc
adaptation context and remain accurate as ancestry; the current authoritative pin is `112803c`.
The pinned fork `master` (944f7d1, now 112803c) carries a
srvsvc DCE/RPC API rename beyond the transport additions (upstream `srvsvc_SHARE_INFO_1_carray`
→ `srvsvc_SHARE_INFO_1_CONTAINER`, inline char arrays → nullable `char *`, `max_count` →
`EntriesRead`), so `AMSMB2/Parsers.swift` requires a corresponding adaptation — specifically
`Array<SMB2Share>.init(_ container:)` — to compile against the fork. This adaptation is the
only required AMSMB2 Swift source change for this task.

#### Scenario: Submodule URL retargeted

- **WHEN** `.gitmodules` is inspected
- **THEN** the `Dependencies/libsmb2` URL is `https://github.com/simplekube-ro/libsmb2`
- **AND** the pinned commit contains `smb2_set_transport` in `include/smb2/libsmb2.h`

#### Scenario: Fresh clone builds and existing tests stay green

- **WHEN** the submodule is initialized and `swift build --disable-sandbox` then
  `swift test --disable-sandbox` are run
- **THEN** the build succeeds (including the adapted `Parsers.swift` for the fork's srvsvc API)
- **AND** the existing unit-test suite passes (integration tests skip without a server)
- **AND** the two new null-NDR-referent regression tests (`testShareContainerWithNullRemark`,
  `testShareContainerWithNullNetname`) pass

### Requirement: External-transport C symbols are importable from the Swift SMB2 module

The Swift `SMB2` module SHALL expose the libsmb2 external-transport C symbols to Swift via
`import SMB2`, namely: `smb2_set_transport`, `smb2_external_transport` (with fields `userdata`,
`connect`, `send`, `recv`, `close`), `SMB2_TRANSPORT_TCP`, `SMB2_TRANSPORT_QUIC`,
`SMB2_TRANSPORT_AUTO`, `smb2_get_timeout`, and `smb2_service_timeout`. A compile-time smoke test in
the test target SHALL reference each symbol and struct field so that a regression fails the build.

#### Scenario: Symbols referenced from a Swift test compile

- **WHEN** a test file does `import SMB2` and references all five symbols plus every
  `smb2_external_transport` field
- **THEN** the test target compiles under `swift build --disable-sandbox`
- **AND** `swift test --disable-sandbox` passes

#### Scenario: Transport-kind constants have the expected values

- **WHEN** the smoke test reads the transport-kind constants
- **THEN** `SMB2_TRANSPORT_TCP == 0`, `SMB2_TRANSPORT_QUIC == 1`, and `SMB2_TRANSPORT_AUTO == 2`

### Requirement: SwiftNIO and NIOTransportServices available to the AMSMB2 target, Apple-guarded

`Package.swift` SHALL add `swift-nio` (`NIOCore`, and `NIOPosix` only if a test requires it) and
`swift-nio-transport-services` (`NIOTransportServices`), pinned to current stable major versions,
to the main `AMSMB2` target. All NIO usage SHALL be guarded so the Linux build compiles with no
NIO transport code and no Network.framework symbol references. Apache-2.0 notices for SwiftNIO and
NIOTransportServices SHALL be recorded alongside the existing libsmb2 LGPL note.

#### Scenario: Apple build resolves NIO

- **WHEN** `swift build --disable-sandbox` runs on an Apple platform
- **THEN** SwiftNIO and NIOTransportServices resolve and the build succeeds

#### Scenario: Linux build is unaffected

- **WHEN** the package is built for Linux
- **THEN** no `import NIOTransportServices` / Network.framework symbol is required and the build
  path remains compilable

#### Scenario: Third-party license notices recorded

- **WHEN** the project's license documentation is inspected
- **THEN** Apache-2.0 notices for SwiftNIO and NIOTransportServices are present alongside the
  libsmb2 LGPL v2.1 note
