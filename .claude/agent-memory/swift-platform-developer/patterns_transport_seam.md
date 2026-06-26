# Transport Seam Patterns (T4–T9)

## Files introduced by T4

- `AMSMB2/SMBTransport.swift` — public protocol + enum (Foundation only, no NIO, no platform guard)
- `AMSMB2Tests/MockTransport.swift` — actor-based in-memory loopback double
- `AMSMB2Tests/SMBTransportTests.swift` — 9 unit tests

## Protocol shape (design D2)

```swift
public protocol SMBTransport: Sendable {
    func connect(host: String, port: Int) async throws
    func send(_ bytes: Data) async throws
    func receive() async throws -> Data   // empty Data = graceful EOF
    func close() async
}
public enum SMBTransportKind: Sendable, Equatable, Hashable { case tcp, quic, automatic }
```

Buffer type is `Data` (not NIO `ByteBuffer`). Concrete transports convert internally.

## MockTransport capabilities

- Default init: `.succeed` connect, loopback send→receive
- `connectBehavior: .fail(error)` — throws on connect
- `signalGracefulEOF()` — next receive returns `Data()`; queued bytes drained first
- Never-reply: default when queue empty and no EOF; outer Task cancellation unblocks it
- Reused by T5 bridge tests and T6 servicing tests

## Branch stack

```
master
└── feat/tcp-transport-submodule   (T1 — libsmb2 fork retarget)
    └── feat/tcp-transport-c-symbols (T2 — C symbol exposure)
        └── feat/tcp-transport-nio-deps (T3 — NIO Package.swift)
            └── feat/tcp-transport-protocol (T4 — seam protocol + mock)
                └── (future T5 bridge, T6 servicing, T7 TCPTransportApple …)
```

## D1 naming trap (critical)

`SMB2_TRANSPORT_TCP == 0` selects libsmb2's BUILT-IN socket and IGNORES the `ext` struct.
To use an external transport, ALWAYS pass `SMB2_TRANSPORT_QUIC` or `SMB2_TRANSPORT_AUTO`.
Assert `smb2_get_fd(context) == -1` when the seam is active.
