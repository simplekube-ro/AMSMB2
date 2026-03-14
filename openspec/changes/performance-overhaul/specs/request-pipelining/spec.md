## ADDED Requirements

### Requirement: Multiple SMB2 requests in-flight simultaneously
The system SHALL support multiple SMB2 read/write requests queued and in-flight over a single TCP connection. The number of concurrent in-flight requests SHALL be bounded by the server-granted SMB2 credits.

#### Scenario: Pipelined sequential read
- **WHEN** a file read operation is issued for a file larger than one chunk
- **THEN** multiple `smb2_pread_async()` calls are queued before waiting for any reply
- **AND** the total in-flight requests do not exceed available SMB2 credits

#### Scenario: Credit exhaustion
- **WHEN** all available SMB2 credits are consumed by in-flight requests
- **THEN** additional requests are held in the submission queue until credits are replenished by server replies
- **AND** no request is dropped or fails due to credit exhaustion

### Requirement: Ordered result delivery for pipelined reads
When pipelining read operations for a single file, results SHALL be delivered to the caller in offset order, regardless of the order in which server replies arrive.

#### Scenario: Out-of-order replies
- **WHEN** the server replies to pipelined read requests in a different order than they were sent
- **THEN** the results are reassembled in the correct offset order before being delivered to the caller

### Requirement: Pipelined write support
Write operations for a single file SHALL support pipelining: multiple `smb2_pwrite_async()` calls queued before waiting for acknowledgments, bounded by credits.

#### Scenario: Pipelined sequential write
- **WHEN** a file write operation is issued with data larger than one chunk
- **THEN** multiple `smb2_pwrite_async()` calls are queued concurrently
- **AND** write acknowledgments are tracked to confirm all data was written

#### Scenario: Write failure mid-pipeline
- **WHEN** one write in a pipelined sequence fails
- **THEN** remaining queued writes for that operation are cancelled
- **AND** the error is propagated to the caller with the offset of the failure

### Requirement: Independent operations remain independent
Operations on different file handles or different types (e.g., a read on file A and a stat on file B) SHALL be independently pipelined — neither blocks the other.

#### Scenario: Concurrent operations on different files
- **WHEN** two callers issue operations on different file handles simultaneously
- **THEN** both operations are submitted to libsmb2 without either waiting for the other's completion
