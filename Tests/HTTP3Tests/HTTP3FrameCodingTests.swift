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
import HTTPTypes
import NIOCore
import QPACK
import Testing

struct HTTP3FrameCodingTests {
    @Test
    func testDecodeInvalidFrame() throws {
        var decoder = HTTP3FrameDecoder()
        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(2, strategy: .quic)  // type 2 was used in http/2, and forbidden in http/3

        expectH3Error(code: .forbiddenFrameType, h3ErrorCode: .frameUnexpected) {
            _ = try decoder.decode(buffer: &buffer)
        }
    }

    // MARK: DATA frames

    @Test
    func testDecodePartialDataFrame() throws {
        var decoder = HTTP3FrameDecoder()
        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(HTTP3FrameType.data.rawValue, strategy: .quic)

        let frame = try decoder.decode(buffer: &buffer)

        #expect(frame == nil)
    }

    @Test
    func testEncodeDataFrame() {
        let dataFrameBuffer = ByteBuffer(string: "Test")
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(.data(dataFrameBuffer), preferHuffmanEncoding: false)

        #expect(buffer == ByteBuffer([0x00, 0x04, 0x54, 0x65, 0x73, 0x74]))
    }

    @Test
    func testEncodeDecodeDataFrame() throws {
        var decoder = HTTP3FrameDecoder()
        let dataFrameBuffer = ByteBuffer(string: "Test")
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(.data(dataFrameBuffer), preferHuffmanEncoding: false)
        let frame = try decoder.decode(buffer: &buffer)

        #expect(frame == .known(.data(dataFrameBuffer)))
        #expect(buffer.readableBytes == 0)
    }

    @Test
    func testEncodeDecodeTwoDataFrames() throws {
        var decoder = HTTP3FrameDecoder()
        let dataFrameBuffer1 = ByteBuffer(string: "Test1")
        let dataFrameBuffer2 = ByteBuffer(string: "Test2")
        var out = ByteBuffer()

        out.writeHTTP3PartialFrame(.data(dataFrameBuffer1), preferHuffmanEncoding: false)
        out.writeHTTP3PartialFrame(.data(dataFrameBuffer2), preferHuffmanEncoding: false)
        let frame1 = try decoder.decode(buffer: &out)
        let frame2 = try decoder.decode(buffer: &out)

        #expect(frame1 == .known(.data(dataFrameBuffer1)))
        #expect(frame2 == .known(.data(dataFrameBuffer2)))
        #expect(out.readableBytes == 0)
    }

    @Test
    func testDecodeDataFrameInParts() throws {
        var decoder = HTTP3FrameDecoder()

        var out = ByteBuffer()

        // Write the type only
        out.writeEncodedInteger(0, strategy: .quic)
        #expect(try decoder.decode(buffer: &out) == nil)
        #expect(out.readableBytes == 0)
        let hasLeftovers1 = decoder.hasPartialFrame
        #expect(hasLeftovers1)

        // Write the length only
        out.writeEncodedInteger(10, strategy: .quic)
        try #expect(decoder.decode(buffer: &out) == nil)
        #expect(out.readableBytes == 0)
        let hasLeftovers2 = decoder.hasPartialFrame
        #expect(hasLeftovers2)

        // Write incomplete (< 10 bytes) payload. The decoder will form a frame out of these
        out.writeBytes([1, 2, 3, 4, 5])
        #expect(try decoder.decode(buffer: &out) == .known(.data(.init(bytes: [1, 2, 3, 4, 5]))))
        #expect(out.readableBytes == 0)
        let hasLeftovers3 = decoder.hasPartialFrame
        #expect(hasLeftovers3)

        // Complete the payload
        out.writeBytes([6, 7, 8, 9, 10])
        #expect(try decoder.decode(buffer: &out) == .known(.data(.init(bytes: [6, 7, 8, 9, 10]))))
        #expect(out.readableBytes == 0)
        let hasLeftovers4 = decoder.hasPartialFrame
        #expect(!hasLeftovers4)
    }

    @Test
    func testDecodeEmptyDataFrame() throws {
        var decoder = HTTP3FrameDecoder()

        var out = ByteBuffer()

        // 0 for the type, 0 for the length
        out.writeEncodedInteger(0, strategy: .quic)
        out.writeEncodedInteger(0, strategy: .quic)
        #expect(try decoder.decode(buffer: &out) == .known(.data(ByteBuffer())))
        #expect(out.readableBytes == 0)
        let hasLeftovers = decoder.hasPartialFrame
        #expect(!hasLeftovers)
    }

    // MARK: CANCEL_PUSH frames

    @Test
    func testEncodeCancelPushFrame() {
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(
            .cancelPush(HTTP3PushID(rawValue: 151_288_809_941_952_652)),
            preferHuffmanEncoding: false
        )

        #expect(buffer == ByteBuffer([0x03, 0x08, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c]))
    }

    @Test
    func testEncodeDecodeCancelPushFrame() throws {
        var decoder = HTTP3FrameDecoder()
        let pushID = HTTP3PushID(rawValue: 151_288_809_941_952_652)
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(.cancelPush(pushID), preferHuffmanEncoding: false)
        let frame = try decoder.decode(buffer: &buffer)

        #expect(frame == .known(.cancelPush(pushID)))
        #expect(buffer.readableBytes == 0)
    }

    // MARK: SETTINGS frames

    @Test
    func testEncodeSettingsFrame() {
        let settings = HTTP3Settings(
            qpackMaximumTableCapacity: 151_288_809_941_952_652,
            qpackBlockedStreams: 1
        )
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(.settings(settings), preferHuffmanEncoding: false)

        #expect(
            buffer
                // The frame type is 4
                // The length is 11, but it's encoded across 2 bytes
                // First we have 0x40 (to indicate we're using 2 bytes) and then the actual length of 11 (0x0b)
                == ByteBuffer([0x04, 0x40, 0x0b, 0x07, 0x01, 0x01, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c])
        )
    }

    @Test
    func testEncodeDecodeSettingsFrame() throws {
        var decoder = HTTP3FrameDecoder()
        let settings = HTTP3Settings(
            qpackMaximumTableCapacity: 151_288_809_941_952_652,
            qpackBlockedStreams: 1
        )
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(.settings(settings), preferHuffmanEncoding: false)
        let frame = try decoder.decode(buffer: &buffer)

        #expect(frame == .known(.settings(settings)))
        #expect(buffer.readableBytes == 0)
    }

    @Test
    func testEncodeDecodeSettingsFrame_emptySettings() throws {
        var decoder = HTTP3FrameDecoder()
        let settings = HTTP3Settings()
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(.settings(settings), preferHuffmanEncoding: false)
        let frame = try decoder.decode(buffer: &buffer)

        #expect(frame == .known(.settings(settings)))
        #expect(buffer.readableBytes == 0)
    }

    // MARK: GOAWAY frames

    @Test
    func testEncodeGoawayFrame() {
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(.goaway(151_288_809_941_952_652), preferHuffmanEncoding: false)

        #expect(buffer == ByteBuffer([0x07, 0x08, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c]))
    }

    @Test
    func testEncodeGoawayPushFrame() throws {
        var decoder = HTTP3FrameDecoder()
        let pushID: HTTP3GoawayID = 151_288_809_941_952_652
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(.goaway(pushID), preferHuffmanEncoding: false)
        let frame = try decoder.decode(buffer: &buffer)

        #expect(frame == .known(.goaway(pushID)))
        #expect(buffer.readableBytes == 0)
    }

    @Test
    func testDecodeGoawayRedundantBytes() throws {
        // Type 7 (goaway), length 2, id 1. The id is not actually 2 bytes so this is an error
        var buffer = ByteBuffer(bytes: [7, 2, 1, 0])
        var decoder = HTTP3FrameDecoder()
        expectH3Error(
            code: .invalidFramePayload,
            h3ErrorCode: .frameError,
            message: "Frame length longer than payload"
        ) {
            _ = try decoder.decode(buffer: &buffer)
        }
    }

    @Test
    func testDecodeGoawayNotEnoughBytes() throws {
        // Type 7 (goaway), length 1, id 64. 64 can't be encoded in a single byte in the QUIC format
        // This is an error. This is NOT a case of waiting for more bytes. We've set the length to 1, and provided one byte.
        // But that one byte is insufficient to make a valid frame. It is malformed.
        var buffer = ByteBuffer(bytes: [7, 1, 64])
        var decoder = HTTP3FrameDecoder()
        expectH3Error(code: .invalidFramePayload, h3ErrorCode: .frameError, message: "Invalid frame payload") {
            _ = try decoder.decode(buffer: &buffer)
        }
    }

    // MARK: MAX_PUSH_ID frames

    @Test
    func testEncodeMaxPushIDFrame() {
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(
            .maxPushID(HTTP3PushID(rawValue: 151_288_809_941_952_652)),
            preferHuffmanEncoding: false
        )

        #expect(buffer == ByteBuffer([0x0d, 0x08, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c]))
    }

    @Test
    func testEncodeDecodeMaxPushIDFrame() throws {
        var decoder = HTTP3FrameDecoder()
        let pushID = HTTP3PushID(rawValue: 151_288_809_941_952_652)
        var buffer = ByteBuffer()

        buffer.writeHTTP3PartialFrame(.maxPushID(pushID), preferHuffmanEncoding: false)
        let frame = try decoder.decode(buffer: &buffer)

        #expect(frame == .known(.maxPushID(pushID)))
        #expect(buffer.readableBytes == 0)
    }

    // MARK: PUSH_PROMISE frames

    @Test
    func testEncodePushPromiseFrame() {
        var buffer = ByteBuffer()

        let testFieldSection = FieldSection(
            prefix: .init(
                encodedRequiredInsertCount: 0,
                deltaBase: 0,
                signBit: false
            ),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
        )
        buffer.writeHTTP3PartialFrame(
            .pushPromise(.init(pushID: 77, fieldSection: testFieldSection)),
            preferHuffmanEncoding: false
        )

        #expect(
            buffer
                == ByteBuffer([
                    // frame type 5
                    5,
                    // Fields are length 13, the push id itself is length 2 (numbers over 64 need 2 bytes to encode)
                    // Total length 15, but it's encoded across 4 bytes because of the way NIO's ByteBuffer/writeLengthPrefixed function works
                    // First we have 0x80 (to indicate we're using 4 bytes, see RFC 9000) and then the actual length of 15 in the 4th byte
                    0x80, 0, 0, 15,
                    // Push ID (77, but encoded in QUIC, so we need to prefix with 64)
                    64, 77,
                    // required insert count, delta and base are 0
                    0, 0,
                    // field line
                    // 001 for literal, 0 for N, 0100 for length of name (4)
                    0b00100100,
                    // "test"
                    0b01110100, 0b01100101, 0b01110011, 0b01110100,
                    // 0 (no huffman) then length of value 0000101 (5)
                    0b00000101,
                    // "value"
                    0b01110110, 0b01100001, 0b01101100, 0b01110101, 0b01100101,
                ])
        )
    }

    @Test
    func testEncodePushPromiseFrameWithHuffman() {
        var buffer = ByteBuffer()

        let testFieldSection = FieldSection(
            prefix: .init(
                encodedRequiredInsertCount: 0,
                deltaBase: 0,
                signBit: false
            ),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
        )
        buffer.writeHTTP3PartialFrame(
            .pushPromise(.init(pushID: 77, fieldSection: testFieldSection)),
            preferHuffmanEncoding: true
        )

        #expect(
            buffer
                == ByteBuffer(
                    [
                        // frame type 5
                        5,
                        // Fields are length 11, the push id itself is length 2 (numbers over 64 need 2 bytes to encode)
                        // Total length 13, but it's encoded across 4 bytes because of the way NIO's ByteBuffer/writeLengthPrefixed function works
                        // First we have 0x80 (to indicate we're using 4 bytes, see RFC 9000) and then the actual length of 13 in the 4th byte
                        0x80, 0, 0, 13,
                        // Push ID (77, but encoded in QUIC, so we need to prefix with 64)
                        64, 77,
                        // required insert count, delta and base are 0
                        0, 0,
                        // field line
                        // 001 for literal, 0 for N, 1 for H, 011 for length of name (3 when huffman encoded)
                        0b00101011,
                    ] + "test".huffmanEncodedBytes
                        // 1 (huffman) then length of value 0000100 (4 when huffman encoded)
                        + [0b10000100]
                        // "value"
                        + "value".huffmanEncodedBytes
                )
        )
    }

    @Test(arguments: [true, false])
    func testEncodeDecodePushPromiseFrame(preferHuffmanEncoding: Bool) throws {
        var decoder = HTTP3FrameDecoder()
        var buffer = ByteBuffer()
        let testFieldSection = FieldSection(
            prefix: .init(
                encodedRequiredInsertCount: 0,
                deltaBase: 0,
                signBit: false
            ),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
        )
        let testFrame = HTTP3PartialFrame.pushPromise(.init(pushID: 38, fieldSection: testFieldSection))
        buffer.writeHTTP3PartialFrame(testFrame, preferHuffmanEncoding: preferHuffmanEncoding)
        let frame = try decoder.decode(buffer: &buffer)

        #expect(frame == .known(testFrame))
        #expect(buffer.readableBytes == 0)
    }

    // MARK: HEADER frames

    @Test
    func testEncodeHeaders() throws {
        var buffer = ByteBuffer()

        let testFieldSection = FieldSection(
            prefix: .init(
                encodedRequiredInsertCount: 0,
                deltaBase: 0,
                signBit: false
            ),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
        )
        buffer.writeHTTP3PartialFrame(.headers(.init(fieldSection: testFieldSection)), preferHuffmanEncoding: false)

        #expect(
            buffer
                == ByteBuffer([
                    // frame type 1
                    1,
                    // length 13, but it's encoded across 4 bytes because of the way NIO's ByteBuffer/writeLengthPrefixed function works
                    // First we have 0x80 (to indicate we're using 4 bytes, see RFC 9000) and then the actual length of 13 in the 4th byte
                    0x80, 0, 0, 13,
                    // required insert count, delta and base are 0
                    0, 0,
                    // field line
                    // 001 for literal, 0 for N, 0100 for length of name (4)
                    0b00100100,
                    // "test"
                    0b01110100, 0b01100101, 0b01110011, 0b01110100,
                    // 0 (no huffman) then length of value 0000101 (5)
                    0b00000101,
                    // "value"
                    0b01110110, 0b01100001, 0b01101100, 0b01110101, 0b01100101,
                ])
        )
    }

    @Test
    func testEncodeHeadersWithHuffman() throws {
        var buffer = ByteBuffer()

        let testFieldSection = FieldSection(
            prefix: .init(
                encodedRequiredInsertCount: 0,
                deltaBase: 0,
                signBit: false
            ),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
        )
        buffer.writeHTTP3PartialFrame(.headers(.init(fieldSection: testFieldSection)), preferHuffmanEncoding: true)

        #expect(
            buffer
                == ByteBuffer(
                    [
                        // frame type 1
                        1,
                        // length 11, but it's encoded across 4 bytes because of the way NIO's ByteBuffer/writeLengthPrefixed function works
                        // First we have 0x80 (to indicate we're using 4 bytes, see RFC 9000) and then the actual length of 11 in the 4th byte
                        0x80, 0, 0, 11,
                        // required insert count, delta and base are 0
                        0, 0,
                        // field line
                        // 001 for literal, 0 for N, 1 for H, 0011 for length of name (3 when huffman encoded)
                        0b00101011,
                        // "test"
                    ] + "test".huffmanEncodedBytes
                        // 1 (huffman) then length of value 0000100 (4 when huffman encoded)
                        + [0b10000100]
                        + "value".huffmanEncodedBytes
                )
        )
    }

    @Test(arguments: [true, false])
    func testEncodeDecodeHeaders(preferHuffmanEncoding: Bool) throws {
        var decoder = HTTP3FrameDecoder()

        var buffer = ByteBuffer()
        let testFieldSection = FieldSection(
            prefix: .init(
                encodedRequiredInsertCount: 0,
                deltaBase: 0,
                signBit: false
            ),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
        )
        buffer.writeHTTP3PartialFrame(
            .headers(.init(fieldSection: testFieldSection)),
            preferHuffmanEncoding: preferHuffmanEncoding
        )

        let frame = try decoder.decode(buffer: &buffer)
        guard case .known(.headers(let partialHeader)) = frame else {
            Issue.record("Unexpected frame type")
            return
        }
        #expect(partialHeader.fieldSection == testFieldSection)
    }

    @Test(arguments: [true, false])
    func testEncodeDecodeTwoHeaderFrames(preferHuffmanEncoding: Bool) throws {
        var decoder = HTTP3FrameDecoder()

        var out = ByteBuffer()

        let headers1 = HTTP3PartialFrame.Headers(
            fieldSection: .init(
                prefix: .init(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
                lines: [.literal(requireLiteralRepresentation: false, name: "hello", value: "world")]
            )
        )
        let headers2 = HTTP3PartialFrame.Headers(
            fieldSection: .init(
                prefix: .init(encodedRequiredInsertCount: 1, deltaBase: 0, signBit: false),
                lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
            )
        )

        out.writeHTTP3PartialFrame(.headers(headers1), preferHuffmanEncoding: preferHuffmanEncoding)
        out.writeHTTP3PartialFrame(.headers(headers2), preferHuffmanEncoding: preferHuffmanEncoding)
        let frame1 = try decoder.decode(buffer: &out)
        let frame2 = try decoder.decode(buffer: &out)

        #expect(frame1 == .known(.headers(headers1)))
        #expect(frame2 == .known(.headers(headers2)))
        #expect(out.readableBytes == 0)
    }

    @Test(arguments: [true, false])
    func testDecodeHeadersRedundantBytes(preferHuffmanEncoding: Bool) throws {
        var buffer = ByteBuffer()
        let testFieldSection = FieldSection(
            prefix: .init(
                encodedRequiredInsertCount: 0,
                deltaBase: 0,
                signBit: false
            ),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
        )
        // We make a buffer containing almost a normal headers frame...but we add a 0 to the end.
        // The length field of the frame includes the 0.
        // That means the actual content of the frame finishes one byte before the end of the frame.
        // That's an error.
        buffer.writeEncodedInteger(HTTP3FrameType.headers.rawValue, strategy: .quic)
        buffer.writeLengthPrefixed(strategy: .quic) { tempBuffer in
            var bytesWritten = 0
            bytesWritten += tempBuffer.writeFieldSectionPrefix(testFieldSection.prefix)
            for line in testFieldSection.lines {
                bytesWritten += tempBuffer.writeFieldLine(line, preferHuffmanEncoding: preferHuffmanEncoding)
            }
            // write 1 extra byte
            bytesWritten += tempBuffer.writeBytes([0])
            return bytesWritten
        }

        var decoder = HTTP3FrameDecoder()
        expectH3Error(
            code: .invalidFramePayload,
            h3ErrorCode: .frameError,
            message: "Frame length longer than payload"
        ) {
            _ = try decoder.decode(buffer: &buffer)
        }
    }

    @Test
    func testDecodeHeadersNotEnoughBytes() throws {
        // Type 1 (headers) but not enough bytes to actually make a full header field section
        var buffer = ByteBuffer(bytes: [1, 1, 0])
        var decoder = HTTP3FrameDecoder()
        expectH3Error(code: .invalidFramePayload, h3ErrorCode: .frameError, message: "Invalid frame payload") {
            _ = try decoder.decode(buffer: &buffer)
        }
    }

    // MARK: Unknown type

    @Test(arguments: 15...100)  // These frame types are unknown, but not forbidden
    func testDecodeUnknownType(frameType: UInt64) throws {
        var decoder = HTTP3FrameDecoder()

        let payload = "hello"
        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(frameType, strategy: .quic)
        buffer.writeLengthPrefixedString(payload, strategy: .quic)
        let frame = try decoder.decode(buffer: &buffer)
        #expect(frame == .unknown)
        #expect(buffer.readableBytes == payload.count)  // payload bytes aren't read until after emitting frame
        let frame2 = try decoder.decode(buffer: &buffer)
        #expect(frame2 == nil)
        #expect(buffer.readableBytes == 0)
    }

    @Test(arguments: 15...100)  // These frame types are unknown, but not forbidden
    func testDecodeReservedTypeFollowedByData(frameType: UInt64) throws {
        var decoder = HTTP3FrameDecoder()
        let dataFrameBuffer = ByteBuffer(string: "Test")

        let payload = "hello"
        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(frameType, strategy: .quic)
        buffer.writeLengthPrefixedString(payload, strategy: .quic)
        buffer.writeHTTP3PartialFrame(.data(dataFrameBuffer), preferHuffmanEncoding: false)

        let frame1 = try decoder.decode(buffer: &buffer)
        let frame2 = try decoder.decode(buffer: &buffer)
        #expect(frame1 == .unknown)
        #expect(frame2 == .known(.data(dataFrameBuffer)))
        #expect(buffer.readableBytes == 0)
    }

    // MARK: Misc

    @Test
    func testPartialFrameType() throws {
        // A type integer beginning with 64 implies more bytes to come
        var buffer = ByteBuffer(bytes: [64])
        var decoder = HTTP3FrameDecoder()
        #expect(try decoder.decode(buffer: &buffer) == nil)
        // The decoder doesn't consume the bytes
        #expect(buffer.readableBytes == 1)
        let hasLeftovers = decoder.hasPartialFrame
        #expect(!hasLeftovers)
    }

    @Test(arguments: [
        (type: HTTP3FrameType.cancelPush, size: 100 as UInt64),
        (type: HTTP3FrameType.goaway, size: 9 as UInt64),
        (type: HTTP3FrameType.settings, size: 1025 as UInt64),
        (type: HTTP3FrameType.unknown(type: 89), size: 16385 as UInt64),
        (type: HTTP3FrameType.headers, size: UInt64(Int32.max) + 1),
        (type: HTTP3FrameType.pushPromise, size: UInt64(Int32.max) + 1),
    ])
    func testOversizedFrame(type: HTTP3FrameType, size: UInt64) throws {
        var buffer = ByteBuffer()
        buffer.writeEncodedInteger(type.rawValue, strategy: .quic)
        buffer.writeEncodedInteger(size, strategy: .quic)

        var decoder = HTTP3FrameDecoder()
        expectH3Error(code: .invalidFramePayload, h3ErrorCode: .excessiveLoad) {
            _ = try decoder.decode(buffer: &buffer)
        }
    }
}
