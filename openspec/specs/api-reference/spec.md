# api-reference Specification

## Purpose
Provide a complete, AI-parseable API reference (`docs/API.md`) that documents every public type and method of AMSMB2, organized by domain, with consistent machine-readable structure and error-condition documentation so developers and AI coding assistants can look up signatures, parameters, return types, and error behavior.

## Requirements
### Requirement: All public types documented

The API reference SHALL document every public type: `SMB2Manager`, `SMB2Client`, `SMB2FileHandle`, `AsyncInputStream`, `SMB2FileChangeType`, `SMB2FileChangeAction`, `SMB2FileChangeInfo`, `SMBTransport`, `SMBTransportKind`, and `TCPTransportApple`. For the transport seam types, the reference SHALL note that they are `public` for extensibility but that transport selection is not currently exposed through the `SMB2Manager` API (Apple connections always use `.automatic`).

#### Scenario: Type lookup
- **WHEN** a developer or AI agent searches for a type name in the API reference
- **THEN** they SHALL find its purpose, conformances, and key properties

#### Scenario: Transport seam types are documented
- **WHEN** a developer looks up `SMBTransport`, `SMBTransportKind`, or `TCPTransportApple`
- **THEN** they SHALL find the protocol surface (`connect`/`send`/`receive`/`close`), the `.tcp`/`.quic`/`.automatic` cases, the Apple-only constraint on `TCPTransportApple`, and a note that the seam is used automatically on Apple and is not yet selectable through the public API

### Requirement: All public methods documented

The API reference SHALL document every public/open method on `SMB2Manager` with its async variant. Each method entry SHALL include: signature, description, parameters, return type, and throws behavior.

#### Scenario: Method lookup
- **WHEN** a developer or AI agent looks up a method name
- **THEN** they SHALL find its complete signature, parameter descriptions, and error conditions

### Requirement: Domain-grouped organization

Methods SHALL be grouped by domain: Connection Management, Share Enumeration, Directory Operations, File Operations, File Attributes, Symbolic Links, Copy/Move, Upload/Download, Streaming, Monitoring.

#### Scenario: Finding related methods
- **WHEN** a developer wants to know all directory-related methods
- **THEN** they SHALL find them grouped together in the Directory Operations section

### Requirement: AI-parseable format

Each method entry SHALL use a consistent markdown structure with machine-parseable headers (`### methodName`), parameter lists, and return type descriptions. No prose-heavy descriptions that require interpretation.

#### Scenario: AI context loading
- **WHEN** an AI coding assistant loads the API reference for context
- **THEN** it SHALL be able to extract method signatures, parameter types, and behavior descriptions programmatically

### Requirement: Error documentation

The API reference SHALL document common error conditions (POSIXError codes) for operations that throw, including: ENOTCONN (not connected), ENOENT (path not found), EEXIST (already exists), EACCES (permission denied), ECONNREFUSED (transport connect refused), and ENOTSUP (unsupported, e.g. the not-yet-implemented QUIC transport). The reference SHALL note that the tabulated numeric values are Darwin `errno` codes and that Linux assigns different numbers to the same symbols.

#### Scenario: Error handling guidance
- **WHEN** a developer catches an error from an AMSMB2 operation
- **THEN** they SHALL be able to look up the error code in the API reference to understand its meaning
