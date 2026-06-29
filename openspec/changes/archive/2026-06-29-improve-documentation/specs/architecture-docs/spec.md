## ADDED Requirements

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

The architecture document SHALL include a Mermaid diagram showing how async operations work: Swift async/await → completion handler → DispatchQueue → withThreadSafeContext → libsmb2 async call → poll loop → callback → continuation resume.

#### Scenario: Async pattern understanding
- **WHEN** a developer reads the async operation flow
- **THEN** they SHALL understand how Swift concurrency bridges to libsmb2's C async model

### Requirement: Thread safety model

The architecture document SHALL describe the thread safety model: NSRecursiveLock on SMB2Client context, NSLock on SMB2FileHandle, connectLock on SMB2Manager, and the DispatchQueue serialization pattern.

#### Scenario: Thread safety understanding
- **WHEN** a developer plans to use the library from multiple threads or actors
- **THEN** they SHALL understand which operations are safe to call concurrently

### Requirement: File structure map

The architecture document SHALL include a table mapping source files to their responsibilities and the layer they belong to.

#### Scenario: Finding code
- **WHEN** a developer needs to modify or understand a specific feature
- **THEN** they SHALL be able to identify the correct source file from the table
