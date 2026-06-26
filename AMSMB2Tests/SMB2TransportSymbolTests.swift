// SMB2TransportSymbolTests.swift
// AMSMB2
//
// Copyright © 2024 Mousavian. Distributed under MIT license.
// All rights reserved.
//
// Compile-time + smoke tests that verify all transport-seam C symbols from
// simplekube-ro/libsmb2 are visible via `import SMB2`. If any symbol is
// renamed, removed, or missing from the module map, this file will fail to
// compile, providing an early regression signal.
//
// Acceptance criteria (issue #21 / T2):
//   - SMB2_TRANSPORT_TCP == 0, SMB2_TRANSPORT_QUIC == 1, SMB2_TRANSPORT_AUTO == 2
//   - smb2_external_transport fields: userdata, connect, send, recv, close
//   - smb2_set_transport, smb2_get_timeout, smb2_service_timeout importable

import SMB2
import XCTest

final class SMB2TransportSymbolTests: XCTestCase, @unchecked Sendable {

    // MARK: - Transport constant values

    func testTransportTCPConstantIsZero() {
        XCTAssertEqual(SMB2_TRANSPORT_TCP, 0, "SMB2_TRANSPORT_TCP must equal 0")
    }

    func testTransportQUICConstantIsOne() {
        XCTAssertEqual(SMB2_TRANSPORT_QUIC, 1, "SMB2_TRANSPORT_QUIC must equal 1")
    }

    func testTransportAUTOConstantIsTwo() {
        XCTAssertEqual(SMB2_TRANSPORT_AUTO, 2, "SMB2_TRANSPORT_AUTO must equal 2")
    }

    // MARK: - smb2_external_transport struct layout

    /// Verifies that smb2_external_transport has the expected fields with the
    /// correct memory layout. If any field is renamed or removed, this test
    /// will fail to compile.
    func testExternalTransportStructFieldsAreAccessible() {
        // MemoryLayout check confirms the struct itself is visible and non-empty.
        let structSize = MemoryLayout<smb2_external_transport>.size
        XCTAssertGreaterThan(structSize, 0, "smb2_external_transport must have non-zero size")

        // Write each field by name; compile fails if any field is missing.
        var transport = smb2_external_transport()

        // userdata: void * -> UnsafeMutableRawPointer?
        transport.userdata = nil

        // connect: int (*)(void *userdata, const char *host, int port)
        transport.connect = nil

        // send: int (*)(void *userdata, const uint8_t *buf, size_t len)
        transport.send = nil

        // recv: int (*)(void *userdata, uint8_t *buf, size_t max_len)
        transport.recv = nil

        // close: int (*)(void *userdata)
        transport.close = nil

        // Field-presence assertions: confirm the field access above compiled.
        XCTAssertNil(transport.userdata)
        XCTAssertNil(transport.connect)
        XCTAssertNil(transport.send)
        XCTAssertNil(transport.recv)
        XCTAssertNil(transport.close)
    }

    // MARK: - Function symbol presence (compile-time)

    /// Verifies smb2_set_transport is importable from the SMB2 module.
    ///
    /// The local typed variable is resolved at compile time; if the symbol is
    /// absent or has an incompatible signature the test file will not compile.
    func testSMB2SetTransportIsImportable() {
        // C signature: int smb2_set_transport(struct smb2_context *smb2, int type,
        //                                     const struct smb2_external_transport *ext)
        let functionRef: @Sendable (
            UnsafeMutablePointer<smb2_context>?, Int32,
            UnsafePointer<smb2_external_transport>?
        ) -> Int32 = smb2_set_transport
        XCTAssertNotNil(functionRef as Any)
    }

    /// Verifies smb2_get_timeout is importable from the SMB2 module.
    func testSMB2GetTimeoutIsImportable() {
        // C signature: int smb2_get_timeout(struct smb2_context *smb2, struct timeval *tv)
        let functionRef: @Sendable (
            UnsafeMutablePointer<smb2_context>?,
            UnsafeMutablePointer<timeval>?
        ) -> Int32 = smb2_get_timeout
        XCTAssertNotNil(functionRef as Any)
    }

    /// Verifies smb2_service_timeout is importable from the SMB2 module.
    func testSMB2ServiceTimeoutIsImportable() {
        // C signature: int smb2_service_timeout(struct smb2_context *smb2)
        let functionRef: @Sendable (UnsafeMutablePointer<smb2_context>?) -> Int32
            = smb2_service_timeout
        XCTAssertNotNil(functionRef as Any)
    }
}
