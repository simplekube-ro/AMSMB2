# architecture-docs Specification

## Purpose
Provide an architecture document (`docs/ARCHITECTURE.md`) that explains the AMSMB2 system through Mermaid diagrams and a file-structure map: the four-layer stack, the connection lifecycle, the async operation flow that bridges Swift concurrency to libsmb2's C async model, the thread-safety model, and the pluggable transport layer (the Apple external-transport seam vs the legacy libsmb2-owned socket path on Linux) — so developers can understand responsibilities, dependency directions, locking strategy, how the wire is driven on each platform, and where to find code.

## Requirements

### Requirement: Layer architecture diagram

The architecture document SHALL include a Mermaid diagram showing the four-layer stack: libsmb2 (C) → SMB2Client (Swift wrapper) → SMB2FileHandle (file abstraction) → SMB2Manager (public API).

#### Scenario: Layer understanding
- **WHEN** a developer reads the architecture document
- **THEN** they SHALL understand which layer handles which responsibility and the dependency direction

### Requirement: Connection lifecycle flow

The architecture document SHALL include a Mermaid sequence diagram showing the connection lifecycle: init → connectShare → operations → disconnectShare, including the role of connectLock and the reconnection pattern.

#### Scenario: Connection flow understanding
- **WHEN** a developer reads the connection lifecycle section
- **THEN** they SHALL understand the locking strategy and when reconnection occurs

### Requirement: Async operation flow

The architecture document SHALL include a Mermaid diagram showing how async operations work: Swift async/await → `CheckedContinuation` (caller suspends) → `eventLoopQueue.async` PDU setup → `smb2_*_async` (queues PDU) → readiness signal (Apple: transport-bridge inbound-ready; Linux: `DispatchSource` fd) → `smb2_service` → `generic_handler` C callback → `continuation.resume`. The diagram SHALL show that everything from `smb2_service` onward is identical across platforms and that only the readiness signal differs.

#### Scenario: Async pattern understanding
- **WHEN** a developer reads the async operation flow
- **THEN** they SHALL understand how Swift concurrency bridges to libsmb2's C async model, and how the readiness signal that triggers `smb2_service` differs between the Apple seam and the Linux socket path

### Requirement: Thread safety model

The architecture document SHALL describe the thread safety model: the serial `eventLoopQueue` (`.userInitiated` `DispatchQueue`) that exclusively owns the `smb2_context`, `connectLock` (`NSLock`) and `operationLock` (`NSCondition`) on `SMB2Manager`, `_handleLock` (`NSLock`) on `SMB2FileHandle`, the `TransportBridge` `NSLock` on Apple, and the platform-specific readiness signalling (`DispatchSource` on Linux, inbound-ready signal on Apple) that all converges on the event loop queue.

#### Scenario: Thread safety understanding
- **WHEN** a developer plans to use the library from multiple threads or actors
- **THEN** they SHALL understand which operations are safe to call concurrently and that all `smb2_context` access is serialized on the event loop queue

### Requirement: Transport layer (Apple seam) documentation

The architecture document SHALL include a Transport Layer section describing the pluggable external-transport seam used on Apple platforms. It SHALL cover: the public seam types (`SMBTransport`, `SMBTransportKind`) and conformer (`TCPTransportApple`) plus the internal `TransportBridge`; that Apple connections default to the seam (`smb2_set_transport` with `SMB2_TRANSPORT_AUTO`, never `SMB2_TRANSPORT_TCP`) so `smb2_get_fd == -1`; the no-fd servicing loop driven by an inbound-ready signal and timer-driven `smb2_service_timeout`; eager transport connect ordering before NEGOTIATE; the pushed inbound path (the transport delivers each chunk into the bridge's store on its own network queue, with no task in between) and the outbound pump task, both with copy-at-the-C-boundary semantics; and that Linux retains libsmb2's built-in socket path. The document SHALL also state that the seam is not currently selectable through the public `SMB2Manager` API.

#### Scenario: Transport seam understanding
- **WHEN** a developer reads the Transport Layer section
- **THEN** they SHALL understand that Apple runs SMB2 over a Swift-owned NIO transport with no socket fd, how servicing is driven without a `DispatchSource`, and that Linux keeps the legacy libsmb2-owned socket

#### Scenario: Platform split is explicit
- **WHEN** a developer compares the Transport Layer and Socket Monitoring (Linux) sections
- **THEN** they SHALL understand which servicing path is compiled on which platform (`#if canImport(Network)`)

### Requirement: File structure map

The architecture document SHALL include a table mapping source files to their responsibilities and the layer they belong to, including the transport seam files (`SMBTransport.swift`, `TransportBridge.swift`, `TCPTransportApple.swift`).

#### Scenario: Finding code
- **WHEN** a developer needs to modify or understand a specific feature
- **THEN** they SHALL be able to identify the correct source file from the table
