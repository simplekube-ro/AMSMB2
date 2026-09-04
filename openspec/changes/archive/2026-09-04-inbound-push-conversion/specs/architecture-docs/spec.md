## MODIFIED Requirements

### Requirement: Transport layer (Apple seam) documentation

The architecture document SHALL include a Transport Layer section describing the pluggable external-transport seam used on Apple platforms. It SHALL cover: the public seam types (`SMBTransport`, `SMBTransportKind`) and conformer (`TCPTransportApple`) plus the internal `TransportBridge`; that Apple connections default to the seam (`smb2_set_transport` with `SMB2_TRANSPORT_AUTO`, never `SMB2_TRANSPORT_TCP`) so `smb2_get_fd == -1`; the no-fd servicing loop driven by an inbound-ready signal and timer-driven `smb2_service_timeout`; eager transport connect ordering before NEGOTIATE; the pushed inbound path (the transport delivers each chunk into the bridge's store on its own network queue, with no task in between) and the outbound pump task, both with copy-at-the-C-boundary semantics; and that Linux retains libsmb2's built-in socket path. The document SHALL also state that the seam is not currently selectable through the public `SMB2Manager` API.

#### Scenario: Transport seam understanding
- **WHEN** a developer reads the Transport Layer section
- **THEN** they SHALL understand that Apple runs SMB2 over a Swift-owned NIO transport with no socket fd, how servicing is driven without a `DispatchSource`, and that Linux keeps the legacy libsmb2-owned socket

#### Scenario: Platform split is explicit
- **WHEN** a developer compares the Transport Layer and Socket Monitoring (Linux) sections
- **THEN** they SHALL understand which servicing path is compiled on which platform (`#if canImport(Network)`)
