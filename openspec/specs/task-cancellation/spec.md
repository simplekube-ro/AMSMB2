# task-cancellation Specification

## Purpose
Provide per-operation Swift Task cancellation via `withTaskCancellationHandler`, integrated with event loop continuation tracking. Every async method honors cancellation, checks for an already-cancelled task before submitting work, releases any resources held at cancellation time, and confines the effect of a cancellation to the single cancelled operation without corrupting the shared connection.

## Requirements

### Requirement: Every async method supports Task cancellation
Every async `SMB2Manager` method SHALL wrap its continuation with `withTaskCancellationHandler`. On cancellation, the handler SHALL remove the continuation from the event loop's tracking and resume it with `CancellationError`.

#### Scenario: Cancellation during an in-flight operation
- **WHEN** a large file read is in progress and the surrounding Task is cancelled after the first chunk
- **THEN** the cancellation handler removes the continuation from the event loop's tracking
- **AND** the continuation is resumed with `CancellationError` within the operation timeout

### Requirement: Fast-path cancellation check before submission
Every async method SHALL call `try Task.checkCancellation()` before submitting work to the event loop. An already-cancelled Task SHALL fail immediately without touching the event loop.

#### Scenario: Task already cancelled before submission
- **WHEN** a Task is cancelled before an operation is started
- **THEN** the method throws `CancellationError` immediately from the fast-path check
- **AND** no request is submitted to the event loop

### Requirement: Cancelled operations must not leak resources
Cancelling an operation SHALL release any resources held at cancellation time. If a CBData is retained at cancellation time, it SHALL be released. If a file handle is open, it SHALL be closed (fire-and-forget). The event loop's outstanding continuation count SHALL decrement.

#### Scenario: Retained CBData is released on cancellation
- **WHEN** an operation is cancelled while it holds a retained CBData
- **THEN** the CBData is released
- **AND** the event loop's outstanding continuation count is decremented

#### Scenario: Open file handle is closed on cancellation
- **WHEN** an operation that has opened a file handle is cancelled
- **THEN** the file handle is closed (fire-and-forget)
- **AND** no resource is leaked

### Requirement: Cancellation must not corrupt connection state
Cancelling one operation SHALL NOT tear down the entire connection. Other in-flight operations on the same connection SHALL continue normally, and only the cancelled operation's continuation SHALL be affected.

#### Scenario: One of two concurrent operations is cancelled
- **WHEN** one of two concurrent operations on the same connection is cancelled
- **THEN** only the cancelled operation's continuation is resumed with `CancellationError`
- **AND** the other operation continues and completes successfully

#### Scenario: Connection remains usable after cancellation
- **WHEN** an operation is cancelled and a new operation is subsequently issued on the same connection
- **THEN** the connection is still usable
- **AND** the new operation completes normally
