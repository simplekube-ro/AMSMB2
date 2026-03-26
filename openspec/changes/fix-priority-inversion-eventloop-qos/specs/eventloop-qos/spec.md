## ADDED Requirements

### Requirement: Event loop queue runs at userInitiated QoS
The `eventLoopQueue` created by `SMB2Client` SHALL be initialized with `DispatchQoS.userInitiated` so that its scheduling priority matches or exceeds that of calling threads performing user-facing file operations.

#### Scenario: No priority inversion when caller is at userInitiated QoS
- **WHEN** a caller at `.userInitiated` QoS invokes `async_await()` and blocks on the semaphore
- **THEN** the `eventLoopQueue` runs at `.userInitiated` QoS, and no priority inversion is reported by the Thread Performance Checker

#### Scenario: Event loop queue label is preserved
- **WHEN** `SMB2Client` is initialized
- **THEN** the `eventLoopQueue` label SHALL still follow the pattern `smb2_eventloop_<address>` (only the QoS changes, not the label or serial behavior)
