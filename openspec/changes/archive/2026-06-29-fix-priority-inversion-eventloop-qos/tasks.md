## 1. Test (Red)

- [x] 1.1 Write a test that asserts `eventLoopQueue` is created with `.userInitiated` QoS (verifies the queue's QoS class after `SMB2Client` init)

## 2. Implementation (Green)

- [x] 2.1 Add `qos: .userInitiated` to the `DispatchQueue` initializer in `SMB2Client.init(timeout:)` at Context.swift line ~83

## 3. Verification

- [x] 3.1 Run `swift build` to confirm compilation
- [x] 3.2 Run `swift test` to confirm all tests pass (unit + integration skip)
