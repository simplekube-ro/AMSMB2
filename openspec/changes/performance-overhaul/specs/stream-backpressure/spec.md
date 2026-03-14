## ADDED Requirements

### Requirement: High-water mark pauses prefetching
`AsyncInputStream` SHALL pause its prefetch task when the internal buffer size exceeds a configurable high-water mark (default: 4 MB). The prefetch task SHALL suspend (not spin) until the buffer is consumed below the low-water mark.

#### Scenario: Buffer exceeds high-water mark
- **WHEN** the prefetch task appends data and the buffer size exceeds the high-water mark
- **THEN** the prefetch task suspends and stops reading from the async iterator
- **AND** no additional memory is consumed until the consumer reads data

#### Scenario: Buffer drops below low-water mark
- **WHEN** the consumer reads data and the buffer size drops below the low-water mark (default: 1 MB)
- **THEN** the prefetch task resumes reading from the async iterator

### Requirement: Bounded peak memory usage
The peak memory usage of `AsyncInputStream` SHALL be bounded by approximately high-water mark + one chunk size, regardless of the total size of the underlying async sequence.

#### Scenario: Streaming a large file
- **WHEN** an `AsyncInputStream` wraps a 1 GB async file stream with default settings
- **THEN** peak memory usage for the stream buffer does not exceed approximately 5 MB (4 MB high-water + 1 MB chunk)

### Requirement: Configurable water marks
The high-water and low-water marks SHALL be configurable at `AsyncInputStream` initialization time.

#### Scenario: Custom water marks
- **WHEN** an `AsyncInputStream` is created with high-water mark of 8 MB and low-water mark of 2 MB
- **THEN** the prefetch task pauses at 8 MB and resumes at 2 MB
