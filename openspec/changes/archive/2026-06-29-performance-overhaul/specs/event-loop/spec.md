## ADDED Requirements

### Requirement: Dedicated event loop thread owns the smb2_context
`SMB2Client` SHALL run a dedicated event loop thread that exclusively owns the `smb2_context` pointer. All libsmb2 function calls (including `smb2_*_async`, `smb2_service`, `smb2_which_events`) SHALL execute only on this thread. No other thread SHALL directly access the `smb2_context`.

#### Scenario: Event loop starts on client initialization
- **WHEN** an `SMB2Client` is initialized
- **THEN** a dedicated event loop thread is created and begins running
- **AND** the thread is ready to accept request submissions

#### Scenario: libsmb2 calls execute on event loop thread only
- **WHEN** a caller submits an SMB2 operation (read, write, stat, etc.)
- **THEN** the corresponding `smb2_*_async()` call executes on the event loop thread
- **AND** never on the caller's thread

### Requirement: DispatchSource-based socket monitoring
The event loop SHALL use `DispatchSource.makeReadSource()` and `DispatchSource.makeWriteSource()` to monitor the socket file descriptor. The event loop SHALL NOT use `poll()` or any polling loop with a fixed timeout.

#### Scenario: Socket becomes readable
- **WHEN** the SMB2 server sends a reply and the socket becomes readable
- **THEN** the event loop calls `smb2_service()` with the appropriate revents
- **AND** the latency between socket readability and `smb2_service()` invocation is bounded only by GCD scheduling, not by a poll timeout

#### Scenario: Requests pending for send
- **WHEN** libsmb2 has PDUs in its outqueue that need to be sent
- **THEN** the event loop activates a write source to flush the outqueue
- **AND** deactivates the write source when the outqueue is empty

### Requirement: Thread-safe request submission via MPSC queue
Callers SHALL submit requests to the event loop via a thread-safe multi-producer single-consumer queue. The event loop thread is the sole consumer. Any thread MAY enqueue a request.

#### Scenario: Concurrent submissions from multiple threads
- **WHEN** multiple threads submit requests simultaneously
- **THEN** all requests are enqueued without data races
- **AND** the event loop processes them in FIFO order

#### Scenario: Event loop drains submission queue
- **WHEN** the event loop wakes (due to socket event or new submission signal)
- **THEN** it drains all pending submissions from the queue
- **AND** calls the corresponding `smb2_*_async()` functions for each

### Requirement: CheckedContinuation bridging for async/await
Each submitted request SHALL carry a `CheckedContinuation`. The libsmb2 callback SHALL resume the continuation with the operation's result or error. This bridges libsmb2's callback model to Swift's structured concurrency.

#### Scenario: Successful operation
- **WHEN** libsmb2 invokes the callback with a success status
- **THEN** the continuation is resumed with the result value
- **AND** the caller's `await` completes normally

#### Scenario: Failed operation
- **WHEN** libsmb2 invokes the callback with a non-success NTStatus
- **THEN** the continuation is resumed throwing the corresponding POSIXError
- **AND** the caller's `await` throws the error

#### Scenario: Connection lost while operations pending
- **WHEN** the socket connection drops while operations are in-flight
- **THEN** all pending continuations are resumed with a connection error
- **AND** no continuation is left permanently suspended

### Requirement: Graceful shutdown
The event loop SHALL support graceful shutdown: cancel pending submissions, resume all outstanding continuations with `CancellationError`, tear down `DispatchSource`s, and release the `smb2_context`.

#### Scenario: Client deinitialization
- **WHEN** `SMB2Client.deinit` is called
- **THEN** the event loop stops accepting new submissions
- **AND** all pending continuations are resumed with `CancellationError`
- **AND** the `smb2_context` is destroyed after all callbacks complete

#### Scenario: Explicit disconnect
- **WHEN** `disconnect()` is called while operations are pending
- **THEN** pending operations receive a connection error
- **AND** the event loop remains alive for potential reconnection
