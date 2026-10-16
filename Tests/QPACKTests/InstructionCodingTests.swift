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
import NIOQUICHelpers
import Testing

@_spi(PackageInternal) @testable import QPACK

struct InstructionCodingTests {
    @available(anyAppleOS 27, *)
    @Test func setDynamicTableCapacity() throws {
        let bytes = encodeEncoderInstruction(.setDynamicTableCapacity(20), preferHuffmanEncoding: false)

        #expect(
            bytes
                == [
                    // 001, then 20
                    0b00110100
                ]
        )

        let decoded = try decodeEncoderInstruction(from: bytes)
        #expect(decoded == .setDynamicTableCapacity(20))
    }

    @available(anyAppleOS 27, *)
    @Test func setDynamicTableCapacityTooBig() throws {
        /// 0x20 followed by UInt.max means set the dynamic table size to UInt.max.
        /// This is always an error on any platform, because UInt.max is always more than Int.max and therefore we don't allow it.
        let bytes = encodePrefixedInteger(UInt.max, prefix: 5, prefixBits: 0x20)

        #expect(throws: IntegerReadingError.unrepresentable) {
            try decodeEncoderInstruction(from: bytes)
        }
    }

    @available(anyAppleOS 27, *)
    @Test func insertWithNameReferenceToDynamicTable() throws {
        let bytes = encodeEncoderInstruction(
            .insertWithNameReference(.dynamicTable, relativeIndex: 10, value: "test"),
            preferHuffmanEncoding: false
        )

        #expect(
            bytes
                // 1, then 0 for dynamic, then 10
                == [0b10001010]
                // The length of the value, i.e 4
                + [4]
                // The value
                + "test".utf8
        )

        let decoded = try decodeEncoderInstruction(from: bytes)
        #expect(decoded == .insertWithNameReference(.dynamicTable, relativeIndex: 10, value: "test"))
    }

    @available(anyAppleOS 27, *)
    @Test func insertWithNameReferenceToStaticTable() throws {
        let bytes = encodeEncoderInstruction(
            .insertWithNameReference(.staticTable, relativeIndex: 30, value: "test"),
            preferHuffmanEncoding: false
        )

        #expect(
            bytes
                // 1, then 1 for static, then 30
                == [0b11011110]
                // The length of the value, i.e 4
                + [4]
                // The value
                + "test".utf8
        )

        let decoded = try decodeEncoderInstruction(from: bytes)
        #expect(decoded == .insertWithNameReference(.staticTable, relativeIndex: 30, value: "test"))
    }

    @available(anyAppleOS 27, *)
    @Test func insertWithLiteralName() throws {
        let bytes = encodeEncoderInstruction(
            .insertWithLiteralName(name: "Name", value: "Value"),
            preferHuffmanEncoding: false
        )

        #expect(
            bytes
                // 01, then the length of the name i.e. 4
                == [0b01000100]
                // The name
                + "Name".utf8
                // The length of the value, i.e. 5
                + [5]
                // The value
                + "Value".utf8
        )

        let decoded = try decodeEncoderInstruction(from: bytes)
        #expect(decoded == .insertWithLiteralName(name: "Name", value: "Value"))
    }

    @available(anyAppleOS 27, *)
    @Test func duplicateEntry() throws {
        let bytes = encodeEncoderInstruction(.duplicateEntry(relativeIndex: 28), preferHuffmanEncoding: false)

        #expect(
            bytes
                // 000, then 28
                == [0b00011100]
        )

        let decoded = try decodeEncoderInstruction(from: bytes)
        #expect(decoded == .duplicateEntry(relativeIndex: 28))
    }

    @available(anyAppleOS 27, *)
    @Test(
        arguments: [
            // 160 takes one more byte with a 5-bit prefix than with a 6-bit one, and a string of 160 bytes takes one
            // more byte for its length with a 5-bit prefix than with a 7-bit one, so a bound computed with the wrong
            // prefix comes out short.
            QPACKEncoderInstruction.setDynamicTableCapacity(160),
            .insertWithNameReference(.dynamicTable, relativeIndex: 160, value: String(repeating: "a", count: 160)),
            .insertWithNameReference(.staticTable, relativeIndex: 98, value: String(repeating: "b", count: 20_000)),
            .insertWithLiteralName(name: String(repeating: "n", count: 160), value: String(repeating: "v", count: 160)),
            .duplicateEntry(relativeIndex: 160),
        ],
        [true, false]
    )
    func encoderInstructionWithMultiByteIntegersRoundtrips(
        instruction: QPACKEncoderInstruction,
        preferHuffmanEncoding: Bool
    ) throws {
        let bytes = encodeEncoderInstruction(instruction, preferHuffmanEncoding: preferHuffmanEncoding)

        let decoded = try decodeEncoderInstruction(from: bytes)
        #expect(decoded == instruction)
    }

    @available(anyAppleOS 27, *)
    @Test(
        arguments: [
            // 100 takes one more byte with a 6-bit prefix than with a 7-bit one, and 200 takes one more byte with a
            // 7-bit prefix than with an 8-bit one, so a length computed with the wrong prefix comes out wrong.
            QPACKDecoderInstruction.sectionAcknowledgement(streamID: 100),
            .sectionAcknowledgement(streamID: 200),
            .streamCancellation(streamID: 100),
            .insertCountIncrement(increment: 100),
        ]
    )
    func decoderInstructionWithMultiByteIntegersRoundtrips(instruction: QPACKDecoderInstruction) throws {
        let bytes = encodeDecoderInstruction(instruction)

        let decoded = try decodeDecoderInstruction(from: bytes)
        #expect(decoded == instruction)
    }

    @available(anyAppleOS 27, *)
    @Test func sectionAcknowledgement() throws {
        let bytes = encodeDecoderInstruction(.sectionAcknowledgement(streamID: 8))

        #expect(
            bytes
                // 1, then 8
                == [0b10001000]
        )

        let decoded = try decodeDecoderInstruction(from: bytes)
        #expect(decoded == .sectionAcknowledgement(streamID: 8))
    }

    @available(anyAppleOS 27, *)
    @Test func streamCancellation() throws {
        let bytes = encodeDecoderInstruction(.streamCancellation(streamID: 17))

        #expect(
            bytes
                // 01, then 17
                == [0b01010001]
        )

        let decoded = try decodeDecoderInstruction(from: bytes)
        #expect(decoded == .streamCancellation(streamID: 17))
    }

    @available(anyAppleOS 27, *)
    @Test func insertCountIncrement() throws {
        let bytes = encodeDecoderInstruction(.insertCountIncrement(increment: 55))

        #expect(
            bytes
                // 00, then 55
                == [0b00110111]
        )

        let decoded = try decodeDecoderInstruction(from: bytes)
        #expect(decoded == .insertCountIncrement(increment: 55))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: [(prefix: 7, prefixBits: UInt8(0x80)), (prefix: 6, prefixBits: UInt8(0x40))])
    func streamIDAboveQUICLimitIsUnrepresentable(prefix: Int, prefixBits: UInt8) throws {
        // A QPACK prefixed integer isn't bounded by the QUIC limit of 2^62 - 1 that stream IDs have.
        let bytes = encodePrefixedInteger(UInt64(1) << 62, prefix: prefix, prefixBits: prefixBits)

        #expect(throws: IntegerReadingError.unrepresentable) {
            try decodeDecoderInstruction(from: bytes)
        }
    }

    @available(anyAppleOS 27, *)
    @Test func largestStreamIDDecodes() throws {
        let streamID = QUICStreamID(rawValue: (UInt64(1) << 62) - 1)
        let bytes = encodeDecoderInstruction(.streamCancellation(streamID: streamID))

        let decoded = try decodeDecoderInstruction(from: bytes)
        #expect(decoded == .streamCancellation(streamID: streamID))
    }
}

/// Encodes `instruction` into exactly as much room as ``QPACKEncodedLength/maxEncoderInstruction(_:)`` promises.
@available(anyAppleOS 27, *)
func encodeEncoderInstruction(_ instruction: QPACKEncoderInstruction, preferHuffmanEncoding: Bool) -> [UInt8] {
    encodeBytesWithExactRoom(QPACKEncodedLength.maxEncoderInstruction(instruction)) {
        $0.appendQPACKEncoderInstruction(instruction, preferHuffmanEncoding: preferHuffmanEncoding)
    }.0
}

/// Encodes `instruction`, and checks that it takes exactly as much room as
/// ``QPACKEncodedLength/decoderInstruction(_:)`` says.
@available(anyAppleOS 27, *)
func encodeDecoderInstruction(
    _ instruction: QPACKDecoderInstruction,
    sourceLocation: SourceLocation = #_sourceLocation
) -> [UInt8] {
    let length = QPACKEncodedLength.decoderInstruction(instruction)
    let (bytes, _) = encodeBytesWithExactRoom(length) {
        $0.appendQPACKDecoderInstruction(instruction)
    }
    #expect(bytes.count == length, sourceLocation: sourceLocation)
    return bytes
}

/// Encodes a bare prefixed integer, to make instructions that the encoders won't.
@available(anyAppleOS 27, *)
private func encodePrefixedInteger<Integer: FixedWidthInteger>(
    _ value: Integer,
    prefix: Int,
    prefixBits: UInt8
) -> [UInt8] {
    encodeBytesWithExactRoom(QPACKEncodedLength.prefixedInteger(value, prefix: prefix)) {
        $0.appendQPACKPrefixedInteger(value, prefix: prefix, prefixBits: prefixBits)
    }.0
}

/// Decodes the encoder instruction which takes up the whole of `bytes`.
@available(anyAppleOS 27, *)
private func decodeEncoderInstruction(
    from bytes: [UInt8],
    sourceLocation: SourceLocation = #_sourceLocation
) throws(IntegerReadingError) -> QPACKEncoderInstruction? {
    var buffer = ByteBuffer(bytes: bytes)
    let instruction = try buffer.readQPACKEncoderInstruction()
    #expect(buffer.readableBytes == 0, sourceLocation: sourceLocation)
    return instruction
}

/// Decodes the decoder instruction which takes up the whole of `bytes`.
@available(anyAppleOS 27, *)
private func decodeDecoderInstruction(
    from bytes: [UInt8],
    sourceLocation: SourceLocation = #_sourceLocation
) throws(IntegerReadingError) -> QPACKDecoderInstruction? {
    var buffer = ByteBuffer(bytes: bytes)
    let instruction = try buffer.readQPACKDecoderInstruction()
    #expect(buffer.readableBytes == 0, sourceLocation: sourceLocation)
    return instruction
}
