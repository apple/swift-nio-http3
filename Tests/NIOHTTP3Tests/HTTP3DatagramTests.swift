//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTP3
import NIOCore
import NIOQUICHelpers
import Testing

@testable import NIOHTTP3

struct HTTP3DatagramTests {
    @Test
    func typeFitsInExistentialInlineStorage() {
        #expect(MemoryLayout<HTTP3Datagram>.size <= 24)
    }

    @Test
    func testCoWBehavior() {
        let datagram1 = HTTP3Datagram(streamID: 1, data: ByteBuffer(string: "Hello"))
        var datagram2 = datagram1
        datagram2.streamID = 2

        #expect(datagram1.streamID == 1)
        #expect(datagram2.streamID == 2)
        #expect(datagram1.payload == datagram2.payload)

        var datagram3 = datagram1
        datagram3.payload.writeString(", Datagrams!")
        #expect(datagram3.streamID == 1)
        #expect(datagram3.payload == ByteBuffer(string: "Hello, Datagrams!"))
        #expect(datagram1.payload == ByteBuffer(string: "Hello"))
    }

    @Test
    func datagramFromEmptyBuffer() throws {
        var buffer = ByteBuffer()

        let error = try #require(throws: HTTP3Error.self) {
            _ = try buffer.parseDatagram()
        }

        #expect(error.code == .remoteConnectionError)
        #expect(error.h3ErrorCode == .datagramError)
    }

    @Test
    func datagramWithInvalidQuarterStreamID() throws {
        let invalidQuarterStreamID: UInt64 = 1 << 60
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeEncodedInteger(invalidQuarterStreamID, strategy: .quic)
        #expect(bytesWritten > 0)

        let error = try #require(throws: HTTP3Error.self) {
            _ = try buffer.parseDatagram()
        }

        #expect(error.code == .remoteConnectionError)
        #expect(error.h3ErrorCode == .datagramError)

    }

    @Test(arguments: [42, HTTP3Datagram.largestValidQuarterStreamID])
    func datagramWithValidQuarterStreamID(quarterStreamID: UInt64) throws {
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeEncodedInteger(quarterStreamID, strategy: .quic)
        #expect(bytesWritten > 0)
        buffer.writeString("Hello, Datagram!")

        let datagram = try buffer.parseDatagram()
        #expect(datagram.streamID == QUICStreamID(rawValue: quarterStreamID * 4))
        #expect(String(buffer: datagram.payload) == "Hello, Datagram!")
    }

    @Test
    func writeEmptyDatagramToBuffer() throws {
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeDatagram(HTTP3Datagram(streamID: 40, data: ByteBuffer()))
        #expect(bytesWritten == 1)  // 40 can be encoded in a single byte.

        let decoded = try buffer.parseDatagram()
        #expect(decoded.streamID == 40)
        #expect(decoded.payload == ByteBuffer())
    }

    @Test
    func writeNonEmptyDatagramToBuffer() throws {
        let data = ByteBuffer(repeating: 1, count: 1024)

        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeDatagram(HTTP3Datagram(streamID: 40, data: data))
        #expect(bytesWritten == 1025)  // 1025 = 1 (streamID) + 1024 (data)

        let decoded = try buffer.parseDatagram()
        #expect(decoded.streamID == 40)
        #expect(decoded.payload == data)
    }

    @Test(.enableInDebugBuilds)
    func writeInvalidStreamIDTrapsOnWrite() async {
        @Sendable
        func writeDatagramWithStreamID(_ streamID: QUICStreamID) {
            let datagram = HTTP3Datagram(streamID: streamID, data: ByteBuffer())
            var buffer = ByteBuffer()
            buffer.writeDatagram(datagram)
        }

        // #expect(processExitsWith:expression:) can't capture the stream ID so it's not possible
        // to parameterize these tests.
        await #expect(processExitsWith: .failure) {
            writeDatagramWithStreamID(1)
        }

        await #expect(processExitsWith: .failure) {
            writeDatagramWithStreamID(2)
        }

        await #expect(processExitsWith: .failure) {
            writeDatagramWithStreamID(3)
        }
    }
}
