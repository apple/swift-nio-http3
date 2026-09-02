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
import NIOTestUtils
@_spi(PackageInternal) import QPACK
import Testing

@testable @_spi(PackageInternal) import HTTP3

/// Adapts the single-step ``HTTP3FrameDecoder`` to `ByteToMessageDecoder` so that NIO's
/// `ByteToMessageDecoderVerifier` can drive it.
private struct HTTP3FrameByteToMessageDecoder: NIOSingleStepByteToMessageDecoder {
    typealias InboundOut = HTTP3PartialFrameOrUnknown

    private var decoder = HTTP3FrameDecoder()

    mutating func decode(buffer: inout ByteBuffer) throws -> HTTP3PartialFrameOrUnknown? {
        try self.decoder.decode(buffer: &buffer)
    }

    mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> HTTP3PartialFrameOrUnknown? {
        try self.decoder.decodeLast(buffer: &buffer, seenEOF: seenEOF)
    }
}

struct HTTP3FrameDecoderTests {
    private var testHeader: HTTP3PartialFrame.Headers {
        let fieldSectionPrefix = FieldSectionPrefix(requiredInsertCount: 0, base: 0).encode(maxCapacity: 0)
        let line = FieldLine.literal(requireLiteralRepresentation: false, name: "test", value: "hello")
        return .init(fieldSection: .init(prefix: fieldSectionPrefix, lines: [line]))
    }

    private func encode(_ frame: HTTP3PartialFrame) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeHTTP3PartialFrame(frame, preferHuffmanEncoding: false)
        return buffer
    }

    /// Drive the decoder through NIO's verifier, which drip feeds, batches and interleaves the inputs.
    ///
    /// - Note: DATA frames are deliberately absent: the decoder emits one partial DATA frame per chunk of payload it
    ///   sees, so its output legitimately depends on how the bytes were fed in. They are covered separately below.
    @Test func decoderPassesVerification() throws {
        let frames: [HTTP3PartialFrame] = [
            .settings(.init(qpackMaximumTableCapacity: 1024, h3Datagram: false)),
            .settings(.init(qpackMaximumTableCapacity: 151_288_809_941_952_652, qpackBlockedStreams: 1)),
            .goaway(.init(rawValue: 4)),
            .maxPushID(.init(rawValue: 7)),
            .cancelPush(.init(rawValue: 3)),
            .headers(self.testHeader),
        ]

        var inputOutputPairs: [(ByteBuffer, [HTTP3PartialFrameOrUnknown])] = frames.map {
            (self.encode($0), [.known($0)])
        }

        // Frame type 0x40db is not one we know about. Its payload (here, empty) must be skipped.
        inputOutputPairs.append((ByteBuffer(bytes: [0x40, 0xdb, 0x00]), [.unknown]))
        // The same, but with a payload to skip over.
        inputOutputPairs.append((ByteBuffer(bytes: [0x40, 0xdb, 0x03, 1, 2, 3]), [.unknown]))

        try ByteToMessageDecoderVerifier.verifyDecoder(inputOutputPairs: inputOutputPairs) {
            HTTP3FrameByteToMessageDecoder()
        }
    }

    /// A DATA frame's payload is emitted as it arrives, rather than being buffered until the frame is complete.
    @Test func dataFrameIsEmittedInChunks() throws {
        var decoder = HTTP3FrameDecoder()

        var buffer = ByteBuffer(bytes: [0, 4])  // type data, length 4
        #expect(try decoder.decode(buffer: &buffer) == nil)

        buffer.writeBytes([1, 2])
        #expect(try decoder.decode(buffer: &buffer) == .known(.data(.init(bytes: [1, 2]))))
        #expect(try decoder.decode(buffer: &buffer) == nil)

        buffer.writeBytes([3, 4])
        #expect(try decoder.decode(buffer: &buffer) == .known(.data(.init(bytes: [3, 4]))))
        #expect(try decoder.decode(buffer: &buffer) == nil)

        // The frame is complete, so the decoder is back to expecting a frame type.
        #expect(!decoder.hasPartialFrame)
    }

    @Test func fullDataFrameInOneBuffer() throws {
        var decoder = HTTP3FrameDecoder()
        var buffer = ByteBuffer(bytes: [0, 4, 1, 2, 3, 4])
        #expect(try decoder.decode(buffer: &buffer) == .known(.data(.init(bytes: [1, 2, 3, 4]))))
        #expect(try decoder.decode(buffer: &buffer) == nil)
    }

    @Test(arguments: [2, 6, 8, 9] as [UInt8])
    func forbiddenFrameTypesAreRejected(type: UInt8) {
        var decoder = HTTP3FrameDecoder()
        var buffer = ByteBuffer(bytes: [type])
        expectH3Error(code: .forbiddenFrameType, h3ErrorCode: .frameUnexpected) {
            _ = try decoder.decode(buffer: &buffer)
        }
    }

    @Test func excessivePayloadLengthIsRejected() {
        var decoder = HTTP3FrameDecoder()
        // A SETTINGS frame with a payload length of 4096, which is well above what we're prepared to buffer.
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(HTTP3FrameType.settings.rawValue))
        buffer.writeEncodedInteger(UInt64(4096), strategy: .quic)
        expectH3Error(code: .invalidFramePayload, h3ErrorCode: .excessiveLoad) {
            _ = try decoder.decode(buffer: &buffer)
        }
    }

    @Test func invalidPayloadIsRejected() {
        var decoder = HTTP3FrameDecoder()
        // Type 4 (settings), length 1, identifier 1 - the value is missing.
        var buffer = ByteBuffer(bytes: [4, 1, 1])
        expectH3Error(code: .invalidFramePayload, h3ErrorCode: .frameError) {
            _ = try decoder.decode(buffer: &buffer)
        }
    }

    // MARK: decodeLast

    @Test func decodeLastOnCleanBoundaryProducesNothing() throws {
        var decoder = HTTP3FrameDecoder()
        var buffer = self.encode(.goaway(.init(rawValue: 4)))
        #expect(try decoder.decode(buffer: &buffer) == .known(.goaway(.init(rawValue: 4))))

        #expect(try decoder.decodeLast(buffer: &buffer, seenEOF: true) == nil)
    }

    @Test func decodeLastWithNoInputAtAllProducesNothing() throws {
        var decoder = HTTP3FrameDecoder()
        var buffer = ByteBuffer()
        #expect(try decoder.decodeLast(buffer: &buffer, seenEOF: true) == nil)
    }

    /// RFC 9114 § 7.1: a truncated final frame on a cleanly terminated stream is a H3\_FRAME\_ERROR.
    @Test(
        arguments: [
            [0],  // Frame type 0, no length
            [64],  // Partial frame type (64 implies a multi-byte integer)
            [0, 5, 1],  // Frame type + length but incomplete data (only 1 byte of data, expecting 5)
            [4, 11, 7],  // A settings frame with an incomplete payload
            [0, 1, 1, 0, 1],  // A full frame, followed by a frame with missing payload
        ] as [[UInt8]]
    )
    func decodeLastWithLeftoverBytesIsAnError(testData: [UInt8]) throws {
        var decoder = HTTP3FrameDecoder()
        var buffer = ByteBuffer(bytes: testData)
        // Consume all the complete frames first.
        while try decoder.decode(buffer: &buffer) != nil {}

        expectH3Error(code: .leftoverBytes, h3ErrorCode: .frameError) {
            _ = try decoder.decodeLast(buffer: &buffer, seenEOF: true)
        }
    }

    /// A stream which terminates abruptly may be reset at any point in a frame, so truncation isn't an error there.
    @Test func decodeLastWithLeftoverBytesWithoutEOFIsNotAnError() throws {
        var decoder = HTTP3FrameDecoder()
        var buffer = ByteBuffer(bytes: [0, 5, 1])
        _ = try decoder.decode(buffer: &buffer)
        #expect(try decoder.decodeLast(buffer: &buffer, seenEOF: false) == nil)
    }
}
