## ADDED Requirements

### Requirement: Async callback pointers use Unmanaged

All async SMB2 operations SHALL pass `CBData` references to C callback APIs using `Unmanaged<CBData>.passUnretained(_:).toOpaque()` instead of `withUnsafeMutablePointer(to:_:)`.

#### Scenario: async_await passes stable pointer
- **WHEN** `async_await` passes a callback data pointer to a C function
- **THEN** the pointer SHALL be created via `Unmanaged.passUnretained(cb).toOpaque()` and SHALL remain valid for the entire duration of `wait_for_reply`

#### Scenario: async_await_pdu passes stable pointer
- **WHEN** `async_await_pdu` passes a callback data pointer to a C function
- **THEN** the pointer SHALL be created via `Unmanaged.passUnretained(cb).toOpaque()` and SHALL remain valid for the entire duration of `wait_for_reply`

### Requirement: generic_handler recovers CBData via Unmanaged

The `generic_handler` callback SHALL recover the `CBData` reference using `Unmanaged<CBData>.fromOpaque(_:).takeUnretainedValue()` instead of `bindMemory(to:capacity:).pointee`.

#### Scenario: Callback receives valid CBData
- **WHEN** `generic_handler` is invoked by libsmb2 with a stored callback pointer
- **THEN** it SHALL recover the `CBData` instance via `Unmanaged<CBData>.fromOpaque` and successfully set `isFinished` and invoke `dataHandler`

### Requirement: Change Notify operates without crash

The `monitorItem` API SHALL complete without crashing when monitoring a directory for file changes.

#### Scenario: Monitor detects file creation
- **WHEN** a directory is monitored via `monitorItem` on one connection and a file is created in that directory via a second connection
- **THEN** `monitorItem` SHALL return a non-empty array of `SMB2FileChangeInfo` without crashing

#### Scenario: testMonitor is enabled
- **WHEN** `swift test` is run with a configured SMB server
- **THEN** `testMonitor` SHALL execute (not be skipped) and pass

### Requirement: No regression in existing async operations

All existing async SMB2 operations (connect, read, write, copy, etc.) SHALL continue to function correctly after the pointer management change.

#### Scenario: Full test suite passes
- **WHEN** the full test suite is run against Docker Samba
- **THEN** all previously passing tests SHALL continue to pass with 0 failures
