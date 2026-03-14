## ADDED Requirements

### Requirement: Reusable buffer pool for read operations
`SMB2Client` SHALL maintain a buffer pool that provides pre-allocated `Data` buffers for read operations. Read operations SHALL obtain buffers from the pool instead of allocating new zeroed `Data` on every call.

#### Scenario: Buffer checkout for read
- **WHEN** a read operation begins
- **THEN** a buffer is obtained from the pool without zero-initialization
- **AND** the buffer size is at least `maxReadSize` bytes

#### Scenario: Buffer returned after read completes
- **WHEN** a read operation completes and the result `Data` is returned to the caller
- **THEN** the underlying buffer is returned to the pool for reuse

#### Scenario: Pool empty
- **WHEN** all pooled buffers are in use and a new read is issued
- **THEN** a new buffer is allocated
- **AND** when returned, it is added to the pool if the pool is below its maximum size

### Requirement: Bounded pool size
The buffer pool SHALL hold at most a configurable maximum number of buffers (default: 8). Buffers returned when the pool is full SHALL be released to the system.

#### Scenario: Pool at maximum capacity
- **WHEN** a buffer is returned to the pool and the pool already holds the maximum number of buffers
- **THEN** the returned buffer is released (deallocated) instead of being pooled

### Requirement: Eliminate double-copy on read result
Read operations SHALL NOT create a second `Data` object from the buffer prefix. The buffer SHALL be truncated in-place (adjusting its count) to the number of bytes actually read.

#### Scenario: Partial read
- **WHEN** `smb2_read_async` returns fewer bytes than the buffer size
- **THEN** the returned `Data` reflects only the bytes read
- **AND** no additional memory allocation or copy occurs for the result
