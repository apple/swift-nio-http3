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

@_spi(PackageInternal) @testable import QPACK

struct InstructionCodingTests {
    @Test
    func setDynamicTableCapacity() throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKEncoderInstruction(.setDynamicTableCapacity(20), preferHuffmanEncoding: false)

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                == [
                    // 001, then 20
                    0b00110100
                ]
        )

        let decoded = try buffer.readQPACKEncoderInstruction()
        #expect(decoded == .setDynamicTableCapacity(20))
    }

    @Test
    func setDynamicTableCapacityTooBig() throws {
        var buffer = ByteBuffer()
        /// 0x20 followed by UInt.max means set the dynamic table size to UInt.max.
        /// This is always an error on any platform, because UInt.max is always more than Int.max and therefore we don't allow it.
        buffer.writeQPACKPrefixedInteger(UInt.max, prefix: 5, prefixBits: 0x20)

        #expect(throws: IntegerReadingError.unrepresentable) {
            try buffer.readQPACKEncoderInstruction()
        }
    }

    @Test
    func insertWithNameReferenceToDynamicTable() throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKEncoderInstruction(
            .insertWithNameReference(.dynamicTable, relativeIndex: 10, value: "test"),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                // 1, then 0 for dynamic, then 10
                == [0b10001010]
                // The length of the value, i.e 4
                + [4]
                // The value
                + "test".utf8
        )

        let decoded = try buffer.readQPACKEncoderInstruction()
        #expect(decoded == .insertWithNameReference(.dynamicTable, relativeIndex: 10, value: "test"))
    }

    @Test
    func insertWithNameReferenceToStaticTable() throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKEncoderInstruction(
            .insertWithNameReference(.staticTable, relativeIndex: 30, value: "test"),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                // 1, then 1 for static, then 30
                == [0b11011110]
                // The length of the value, i.e 4
                + [4]
                // The value
                + "test".utf8
        )

        let decoded = try buffer.readQPACKEncoderInstruction()
        #expect(decoded == .insertWithNameReference(.staticTable, relativeIndex: 30, value: "test"))
    }

    @Test
    func insertWithLiteralName() throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKEncoderInstruction(
            .insertWithLiteralName(name: "Name", value: "Value"),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
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

        let decoded = try buffer.readQPACKEncoderInstruction()
        #expect(decoded == .insertWithLiteralName(name: "Name", value: "Value"))
    }

    @Test
    func duplicateEntry() throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKEncoderInstruction(
            .duplicateEntry(relativeIndex: 28),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                // 000, then 28
                == [0b00011100]
        )

        let decoded = try buffer.readQPACKEncoderInstruction()
        #expect(decoded == .duplicateEntry(relativeIndex: 28))
    }

    @Test
    func sectionAcknowledgement() throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKDecoderInstruction(.sectionAcknowledgement(streamID: 8))

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                // 1, then 8
                == [0b10001000]
        )

        let decoded = try buffer.readQPACKDecoderInstruction()
        #expect(decoded == .sectionAcknowledgement(streamID: 8))
    }

    @Test
    func streamCancellation() throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKDecoderInstruction(.streamCancellation(streamID: 17))

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                // 01, then 17
                == [0b01010001]
        )

        let decoded = try buffer.readQPACKDecoderInstruction()
        #expect(decoded == .streamCancellation(streamID: 17))
    }

    @Test
    func insertCountIncrement() throws {
        var buffer = ByteBuffer()
        buffer.writeQPACKDecoderInstruction(.insertCountIncrement(increment: 55))

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                // 00, then 55
                == [0b00110111]
        )

        let decoded = try buffer.readQPACKDecoderInstruction()
        #expect(decoded == .insertCountIncrement(increment: 55))
    }
}
