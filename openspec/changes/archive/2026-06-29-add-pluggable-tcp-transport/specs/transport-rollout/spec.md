## ADDED Requirements

### Requirement: Integration acceptance through the NIO TCP transport

The existing Docker-based Samba integration suite SHALL be runnable through the seam
(`TCPTransportApple` + bridge + servicing loop) via a toggle alongside the `SMB_SERVER`
convention, and SHALL pass the full acceptance matrix: connect, NTLM authentication, directory
listing, large read, large write, and cancel/timeout. The suite SHALL be run both ways and
produce identical outcomes. Because the legacy path is compiled out on Apple after the T9 flip
(`fix-seam-connect-ordering`, C4), the two ways are split across hosts: the **seam** leg runs on
**macOS** (Apple-only transport) and the **legacy** leg runs on **Linux** (its sole remaining
consumer), against the same Samba fixture and the same suite. CI SHALL exercise both legs.

#### Scenario: Acceptance matrix passes through the seam

- **WHEN** the integration suite runs against a Samba server with the seam selected
- **THEN** connect, NTLM auth, directory listing, large read, large write, and cancel/timeout all
  pass

#### Scenario: No observable behavior difference vs legacy

- **WHEN** the suite is run via the legacy path (on Linux) and via the seam (on macOS) against the
  same Samba fixture
- **THEN** the outcomes are identical (no observable behavior difference for TCP)

#### Scenario: CI exercises both legs

- **WHEN** CI runs
- **THEN** there is a macOS leg that exercises the integration suite through the NIO TCP transport
  (seam)
- **AND** there is a Linux leg that exercises the same suite through the legacy libsmb2-owned path

### Requirement: Flip default to TCPTransportApple on Apple after acceptance

Only after the integration acceptance passes, Apple connections SHALL default to
`TCPTransportApple` (the seam) without requiring opt-in. The `automatic` kind on Apple SHALL map
to the seam.

#### Scenario: Apple default uses the seam

- **WHEN** an Apple connection is opened with no explicit transport selection (post-flip)
- **THEN** it connects via `TCPTransportApple` through the seam
- **AND** `smb2_get_fd(context)` returns `-1`

### Requirement: Compile-out legacy DispatchSource path on Apple; retain on Linux

After the flip, the build SHALL compile-out the now-dead Apple legacy socket-handling code in the
same task — `SocketMonitor`, the `DispatchSource` read/write sources, and the fd-readiness servicing
specific to the built-in socket — by guarding it under `#else` of `#if canImport(Network)` so it is
not compiled on Apple, with no orphaned helpers or dead references left behind on Apple. The legacy
libsmb2-owned TCP path SHALL remain compiled and functional on Linux behind that same `#if`
(guard-not-delete: Linux is the sole remaining consumer).

#### Scenario: Apple legacy code removed

- **WHEN** the Apple sources are inspected post-flip
- **THEN** `SocketMonitor` and the legacy `DispatchSource` fd servicing are not compiled on Apple
  (guarded out under `#else` of `#if canImport(Network)`), with no dead references on Apple

#### Scenario: Linux retains the legacy path

- **WHEN** the package is built and tested for Linux
- **THEN** the legacy libsmb2-owned TCP `DispatchSource` path is compiled and functional
- **AND** no NIOTransportServices symbol is required

#### Scenario: Full suite passes by default on Apple

- **WHEN** the full unit + integration suites run on Apple post-flip (seam by default)
- **THEN** they pass
