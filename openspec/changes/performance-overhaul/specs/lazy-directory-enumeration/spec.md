## ADDED Requirements

### Requirement: AsyncSequence-based directory listing
The system SHALL provide a directory listing method that returns an `AsyncThrowingStream` of directory entries, yielding entries on demand rather than loading all entries into memory at once.

#### Scenario: Iterating a large directory
- **WHEN** a caller iterates a directory containing 10,000 entries using the lazy listing API
- **THEN** entries are yielded one at a time (or in small batches)
- **AND** memory usage is proportional to the current batch, not the total directory size

#### Scenario: Early termination
- **WHEN** a caller breaks out of a `for await` loop over the directory stream after 10 entries
- **THEN** the directory handle is closed
- **AND** remaining entries are not fetched from the server

### Requirement: Backward-compatible eager listing
The existing `contentsOfDirectory(atPath:)` method SHALL continue to return `[[URLResourceKey: any Sendable]]` (all entries at once). Internally, it SHALL be reimplemented on top of the lazy listing API.

#### Scenario: Existing code unchanged
- **WHEN** a caller uses `contentsOfDirectory(atPath:)` as before
- **THEN** it returns the same data structure with the same content
- **AND** behavior is identical from the caller's perspective

### Requirement: Lazy recursive listing
Recursive directory listing SHALL enumerate subdirectories lazily — descending into each subdirectory as it is encountered rather than collecting all top-level entries first.

#### Scenario: Recursive listing with early termination
- **WHEN** a caller iterates a recursive directory listing and stops after finding a target file
- **THEN** subdirectories not yet visited are not enumerated
- **AND** the server is not queried for those subdirectories

### Requirement: Eliminate full-scan count
The internal `SMB2Directory.count` property (which performs a full scan) SHALL be deprecated or removed. Code that needs a count SHALL collect entries first.

#### Scenario: Directory count via collection
- **WHEN** a caller needs the number of entries in a directory
- **THEN** they collect the lazy stream into an array and use `.count`
- **AND** no separate full-scan operation exists
