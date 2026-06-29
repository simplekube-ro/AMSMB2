## ADDED Requirements

### Requirement: README reflects the simplekube-ro fork

The README SHALL identify the project as the simplekube-ro fork of AMSMB2 and update all repository URLs accordingly. Badge URLs SHALL point to the fork's repository.

#### Scenario: Fork identification
- **WHEN** a developer reads the README
- **THEN** they SHALL see that this is a fork with additional features (public SMB2Client/SMB2FileHandle API, security hardening, Docker-based integration tests)

### Requirement: Modern async/await code examples

The README SHALL include code examples using Swift's async/await syntax. Examples SHALL cover connection, listing files, reading file contents, and writing files.

#### Scenario: Quick start example compiles
- **WHEN** a developer copies the quick start example into a Swift project that depends on AMSMB2
- **THEN** the code SHALL compile without modification (aside from server URL/credentials)

### Requirement: Documentation links section

The README SHALL include a Documentation section with links to `docs/ARCHITECTURE.md` and `docs/API.md`.

#### Scenario: Links resolve
- **WHEN** a developer clicks the documentation links in the README
- **THEN** they SHALL navigate to the corresponding files in the repository

### Requirement: Testing section

The README SHALL document how to run unit tests (`swift test`), integration tests (`make integrationtest`), and the git submodule prerequisite.

#### Scenario: Developer runs tests
- **WHEN** a developer follows the testing instructions
- **THEN** they SHALL be able to run both unit and integration tests successfully

### Requirement: License section accuracy

The README SHALL accurately describe the dual-license situation (MIT source + LGPL v2.1 libsmb2) and the dynamic linking requirement for App Store distribution.

#### Scenario: License understanding
- **WHEN** a developer reads the license section
- **THEN** they SHALL understand the requirement to link AMSMB2 dynamically
