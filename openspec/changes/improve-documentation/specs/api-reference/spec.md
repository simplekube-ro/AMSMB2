## ADDED Requirements

### Requirement: All public types documented

The API reference SHALL document every public type: `SMB2Manager`, `SMB2Client`, `SMB2FileHandle`, `AsyncInputStream`, `SMB2FileChangeType`, `SMB2FileChangeAction`, `SMB2FileChangeInfo`.

#### Scenario: Type lookup
- **WHEN** a developer or AI agent searches for a type name in the API reference
- **THEN** they SHALL find its purpose, conformances, and key properties

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

The API reference SHALL document common error conditions (POSIXError codes) for operations that throw, including: ENOTCONN (not connected), ENOENT (path not found), EEXIST (already exists), EACCES (permission denied).

#### Scenario: Error handling guidance
- **WHEN** a developer catches an error from an AMSMB2 operation
- **THEN** they SHALL be able to look up the error code in the API reference to understand its meaning
