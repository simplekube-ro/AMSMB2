## ADDED Requirements

### Requirement: Integration acceptance through the NIO TCP transport

The existing Docker-based Samba integration suite SHALL be runnable through the seam
(`TCPTransportApple` + bridge + servicing loop) via a toggle alongside the `SMB_SERVER`
convention, and SHALL pass the full acceptance matrix: connect, NTLM authentication, directory
listing, large read, large write, and cancel/timeout. The suite SHALL be run both ways (legacy
default and seam) and produce identical outcomes, with a CI leg exercising the seam path.

#### Scenario: Acceptance matrix passes through the seam

- **WHEN** the integration suite runs against a Samba server with the seam selected
- **THEN** connect, NTLM auth, directory listing, large read, large write, and cancel/timeout all
  pass

#### Scenario: No observable behavior difference vs legacy

- **WHEN** the suite is run via the legacy path and via the seam
- **THEN** the outcomes are identical (no observable behavior difference for TCP)

#### Scenario: CI exercises the seam leg

- **WHEN** CI runs
- **THEN** there is a leg that exercises the integration suite through the NIO TCP transport

### Requirement: Flip default to TCPTransportApple on Apple after acceptance

Only after the integration acceptance passes, Apple connections SHALL default to
`TCPTransportApple` (the seam) without requiring opt-in. The `automatic` kind on Apple SHALL map
to the seam.

#### Scenario: Apple default uses the seam

- **WHEN** an Apple connection is opened with no explicit transport selection (post-flip)
- **THEN** it connects via `TCPTransportApple` through the seam
- **AND** `smb2_get_fd(context)` returns `-1`

### Requirement: Remove legacy DispatchSource path on Apple; retain on Linux

After the flip, the build SHALL remove the now-dead Apple legacy socket-handling code in the same
task — `SocketMonitor`, the `DispatchSource` read/write sources, and the fd-readiness servicing
specific to the built-in socket — with no orphaned helpers left behind. The legacy libsmb2-owned
TCP path SHALL remain compiled and functional on Linux behind `#if`.

#### Scenario: Apple legacy code removed

- **WHEN** the Apple sources are inspected post-flip
- **THEN** `SocketMonitor` and the legacy `DispatchSource` fd servicing are gone, with no dead
  references to them

#### Scenario: Linux retains the legacy path

- **WHEN** the package is built and tested for Linux
- **THEN** the legacy libsmb2-owned TCP `DispatchSource` path is compiled and functional
- **AND** no NIOTransportServices symbol is required

#### Scenario: Full suite passes by default on Apple

- **WHEN** the full unit + integration suites run on Apple post-flip (seam by default)
- **THEN** they pass
