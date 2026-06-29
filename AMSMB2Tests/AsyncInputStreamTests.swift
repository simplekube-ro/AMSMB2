//
//  AsyncInputStreamTests.swift
//  AMSMB2
//
//  Copyright © 2026 Mousavian. Distributed under MIT license.
//  All rights reserved.
//

import XCTest

@testable import AMSMB2

/// Distinct, identifiable error used to pin G1: the producer error must be surfaced
/// through `streamError` (not dropped and replaced by a generic `EIO` fallback).
private enum StreamTestError: Error, Equatable {
    case boom
}

/// Unit tests (no server) for `AsyncInputStream`'s EOF / would-block semantics.
///
/// These exercise the contract that `read(_:maxLength:)` reports EOF (`0` / `.atEnd`) only
/// after the producer is exhausted, and reports would-block (`-1`, status `.open`) on a
/// transient drain while the producer is still running.
final class AsyncInputStreamTests: XCTestCase, @unchecked Sendable {
    /// Performs a single `read` into a fresh buffer and returns the raw result code.
    private func readOnce(_ stream: InputStream, maxLength: Int) -> Int {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        return stream.read(&buffer, maxLength: maxLength)
    }

    /// Polls `read` until it returns data (`> 0`) or EOF (`0`), retrying on would-block (`-1`).
    /// Returns the bytes read (empty on EOF). Fails the test on timeout.
    private func pollForData(
        _ stream: InputStream, maxLength: Int, timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: maxLength)
            let result = stream.read(&buffer, maxLength: maxLength)
            if result > 0 {
                return Array(buffer.prefix(result))
            }
            if result == 0 {
                return []
            }
            // would-block: yield and retry
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for data from stream", file: file, line: line)
        return []
    }

    /// Waits until `streamStatus` reaches `expected` or the timeout elapses.
    private func waitForStatus(
        _ stream: InputStream, _ expected: Stream.Status, timeout: TimeInterval = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stream.streamStatus == expected { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - C1.2

    func testDrainedBufferWithRunningProducerReportsWouldBlock() async throws {
        var continuation: AsyncStream<Data>.Continuation!
        let sequence = AsyncStream<Data> { continuation = $0 }
        let stream = AsyncInputStream(stream: sequence)
        stream.open()

        let firstChunk = Data(repeating: 0x41, count: 1024)
        continuation.yield(firstChunk)

        // Drain the first chunk fully.
        let received = try await pollForData(stream, maxLength: 4096)
        XCTAssertEqual(received.count, firstChunk.count)

        // Producer is still running (not finished): a drained buffer must report would-block.
        let wouldBlock = readOnce(stream, maxLength: 4096)
        XCTAssertEqual(wouldBlock, -1, "drained-with-running-producer must be would-block")
        XCTAssertEqual(stream.streamStatus, .open, "status must stay .open on would-block")
        XCTAssertNil(stream.streamError, "would-block must not carry an error")

        // Resume the producer and finish: the next bytes must arrive, then EOF.
        let secondChunk = Data(repeating: 0x42, count: 512)
        continuation.yield(secondChunk)
        continuation.finish()

        let receivedSecond = try await pollForData(stream, maxLength: 4096)
        XCTAssertEqual(receivedSecond.count, secondChunk.count)

        let eof = try await pollForData(stream, maxLength: 4096)
        XCTAssertTrue(eof.isEmpty, "after producer finishes and buffer drains, read must report EOF")
        XCTAssertEqual(stream.streamStatus, .atEnd)
    }

    func testEofAfterProducerFinishes() async throws {
        var continuation: AsyncStream<Data>.Continuation!
        let sequence = AsyncStream<Data> { continuation = $0 }
        let stream = AsyncInputStream(stream: sequence)
        stream.open()

        let chunk = Data(repeating: 0x7A, count: 2048)
        continuation.yield(chunk)
        continuation.finish()

        let received = try await pollForData(stream, maxLength: 4096)
        XCTAssertEqual(received.count, chunk.count)

        let eof = try await pollForData(stream, maxLength: 4096)
        XCTAssertTrue(eof.isEmpty)
        XCTAssertEqual(stream.streamStatus, .atEnd)
    }

    func testEmptySourceReportsEofImmediately() async throws {
        let sequence = AsyncStream<Data> { $0.finish() }
        let stream = AsyncInputStream(stream: sequence)
        stream.open()

        let eof = try await pollForData(stream, maxLength: 64)
        XCTAssertTrue(eof.isEmpty, "empty source must report EOF, not hang on would-block")
        XCTAssertEqual(stream.streamStatus, .atEnd)
    }

    // MARK: - C1.3 (G1)

    func testProducerErrorSurfacesStoredError() async throws {
        // The iterator throws on its first `next()` so the error path is deterministic
        // (no race between the consumer draining a buffered chunk and the producer throwing).
        let sequence = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.finish(throwing: StreamTestError.boom)
        }
        let stream = AsyncInputStream(stream: sequence)
        stream.open()

        try await waitForStatus(stream, .error)
        XCTAssertEqual(stream.streamStatus, .error)
        // G1: the actual error is stored, not dropped to a generic EIO fallback.
        XCTAssertEqual(
            stream.streamError as? StreamTestError, .boom,
            "producer error must be surfaced via streamError, not dropped"
        )

        // The error must not be misread as a clean EOF; read returns -1 (terminal error).
        let result = readOnce(stream, maxLength: 64)
        XCTAssertEqual(result, -1)
    }

    func testStatusSnapshotReturnsStoredErrorOnErrorPath() async throws {
        let sequence = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.finish(throwing: StreamTestError.boom)
        }
        let stream = AsyncInputStream(stream: sequence)
        stream.open()

        try await waitForStatus(stream, .error)

        // The snapshot pairs status and error from a single locked read: on the error path it
        // must carry both `.error` and the producer's stored error together (G1).
        let (status, error) = stream.statusSnapshot()
        XCTAssertEqual(status, .error)
        XCTAssertEqual(error as? StreamTestError, .boom)
    }
}
