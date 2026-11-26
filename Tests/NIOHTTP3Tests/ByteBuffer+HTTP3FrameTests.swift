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

import NIOCore
import Testing

@_spi(PackageInternal) @testable import HTTP3
@testable import NIOHTTP3

struct ByteBufferHTTP3FrameTests {
    @available(anyAppleOS 27, *)
    @Test func encodeDataFrame() {
        var buffer = ByteBuffer()

        buffer.writeHTTP3Frame(.data(.init(payload: ByteBuffer(string: "Test"))))

        #expect(buffer == ByteBuffer([0x00, 0x04, 0x54, 0x65, 0x73, 0x74]))
    }

    @available(anyAppleOS 27, *)
    @Test func encodeCancelPushFrame() {
        var buffer = ByteBuffer()

        buffer.writeHTTP3Frame(.cancelPush(.init(pushID: HTTP3PushID(rawValue: 151_288_809_941_952_652))))

        #expect(buffer == ByteBuffer([0x03, 0x08, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c]))
    }

    @available(anyAppleOS 27, *)
    @Test func encodeSettingsFrame() {
        let settings = HTTP3Settings(
            qpackMaximumTableCapacity: 151_288_809_941_952_652,
            qpackBlockedStreams: 1,
            h3Datagram: false,
            enableConnectProtocol: false
        )
        var buffer = ByteBuffer()

        buffer.writeHTTP3Frame(.settings(.init(settings: settings)))

        #expect(
            buffer
                // The frame type is 4
                // The length is 11 (0x0b)
                == ByteBuffer([0x04, 0x0b, 0x07, 0x01, 0x01, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c])
        )
    }

    @available(anyAppleOS 27, *)
    @Test func encodeGoawayFrame() {
        var buffer = ByteBuffer()

        buffer.writeHTTP3Frame(.goaway(.init(id: HTTP3GoawayID(rawValue: 151_288_809_941_952_652))))

        #expect(buffer == ByteBuffer([0x07, 0x08, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c]))
    }

    @available(anyAppleOS 27, *)
    @Test func encodeMaxPushIDFrame() {
        var buffer = ByteBuffer()

        buffer.writeHTTP3Frame(.maxPushID(.init(id: HTTP3PushID(rawValue: 151_288_809_941_952_652))))

        #expect(buffer == ByteBuffer([0x0d, 0x08, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c]))
    }

    /// The payload of ``ByteBuffer/writeHeadersFrame(maxPayloadLength:encodePayload:)`` in the tests below: 13 bytes.
    private static let literalFieldSectionBytes: [UInt8] =
        [
            // required insert count, delta and base are 0
            0, 0,
            // 001 for literal, 0 for N, 0 for H, 0100 for length of name (4)
            0b00100100,
        ] + "test".utf8
        // 0 (no huffman) then length of value 0000101 (5)
        + [0b00000101] + "value".utf8

    @available(anyAppleOS 27, *)
    @Test func writeHeadersFrame() throws {
        var buffer = ByteBuffer()
        buffer.writeHeadersFrame(maxPayloadLength: Self.literalFieldSectionBytes.count) { output in
            for byte in Self.literalFieldSectionBytes {
                output.append(byte)
            }
        }

        // frame type 1, then the length 13, which takes one byte
        #expect(buffer == ByteBuffer([1, 13] + Self.literalFieldSectionBytes))

        var decoder = HTTP3FrameDecoder()
        let frame = try decoder.decode(buffer: &buffer)
        let expected = ByteBuffer(bytes: Self.literalFieldSectionBytes)
        #expect(frame == .known(.headers(.init(fieldSection: expected))))
        #expect(buffer.readableBytes == 0)
    }

    @available(anyAppleOS 27, *)
    @Test func writeHeadersFrameSizesTheLengthForTheLongestPayload() throws {
        var buffer = ByteBuffer()
        // The payload might have been up to 64 bytes long, which takes two bytes to encode as a QUIC integer.
        buffer.writeHeadersFrame(maxPayloadLength: 64) { output in
            for byte in Self.literalFieldSectionBytes {
                output.append(byte)
            }
        }

        // frame type 1, then the length 13, encoded across 2 bytes: 0x40 indicates the 2 byte encoding (RFC 9000)
        #expect(buffer == ByteBuffer([1, 0x40, 13] + Self.literalFieldSectionBytes))

        var decoder = HTTP3FrameDecoder()
        guard case .known(.headers) = try decoder.decode(buffer: &buffer) else {
            Issue.record("Expected a HEADERS frame")
            return
        }
        #expect(buffer.readableBytes == 0)
    }
}
