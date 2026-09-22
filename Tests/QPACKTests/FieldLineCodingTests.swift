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

struct FieldLineCodingTests {
    @Test
    func staticOnlyFieldSectionPrefixRoundtrips() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldSectionPrefix(.staticOnly)

        // Required Insert Count of 0, then a sign bit of 0 followed by a Delta Base of 0.
        #expect(buffer.getBytes(at: 0, length: buffer.readableBytes) == [0, 0])

        #expect(try buffer.readFieldSectionPrefix() == .staticOnly)
    }

    /// The peer may have a dynamic table even though we don't, so the wire format still has to carry a
    /// non-zero Required Insert Count and Delta Base through unharmed. Rejecting those is the decoder's job.
    @Test
    func fieldSectionPrefixRoundtrips() throws {
        for encodedRequiredInsertCount in 0...10 {
            for deltaBase in 0...10 {
                for signBit in [true, false] {
                    let prefix = EncodedFieldSectionPrefix(
                        encodedRequiredInsertCount: encodedRequiredInsertCount,
                        deltaBase: deltaBase,
                        signBit: signBit
                    )
                    var buffer = ByteBuffer()
                    buffer.writeFieldSectionPrefix(prefix)
                    #expect(try buffer.readFieldSectionPrefix() == prefix)
                }
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test func index() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(.indexed(.staticTable, index: 6), preferHuffmanEncoding: false)

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes == [0b11000110]  // 1, then T (1), then the index (6)
        )

        let decoded = try buffer.readFieldLine()
        #expect(decoded == .indexed(.staticTable, index: 6))
    }

    @available(anyAppleOS 26.0, *)
    @Test func indexWithPostBase() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(.indexedWithPostBase(index: 6), preferHuffmanEncoding: false)

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes == [0b00010110]  // 0001, then index (6)
        )

        let decoded = try buffer.readFieldLine()
        #expect(decoded == .indexedWithPostBase(index: 6))
    }

    @available(anyAppleOS 26.0, *)
    @Test func literalWithNameReference() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(
            .literalWithNameReference(
                requireLiteralRepresentation: false,
                table: .dynamicTable,
                index: 9,
                value: "hello"
            ),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                == [0b01001001]  // 01, then N (0), then T (0), then index (9)
                // Then length of value (5)
                + [5]
                // Then value
                + "hello".utf8
        )

        let decoded = try buffer.readFieldLine()
        #expect(
            decoded
                == .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .dynamicTable,
                    index: 9,
                    value: "hello"
                )
        )
    }

    @available(anyAppleOS 26.0, *)
    @Test func literalWithNameReferencePostBase() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(
            .literalWithNameReferenceWithPostBase(requireLiteralRepresentation: false, index: 3, value: "hello"),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                == [0b00000011]  // 0000, then N (0), then index (3)
                // Then length of value (5)
                + [5]
                // Then value
                + "hello".utf8
        )

        let decoded = try buffer.readFieldLine()
        #expect(
            decoded
                == .literalWithNameReferenceWithPostBase(requireLiteralRepresentation: false, index: 3, value: "hello")
        )
    }

    @available(anyAppleOS 26.0, *)
    @Test func literal() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(
            .literal(requireLiteralRepresentation: true, name: "Name", value: "Value"),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                // 001, then N (1), then length of name (4)
                == [0b00110100]
                + "Name".utf8
                // The length of the value, i.e. 5
                + [0b00000101]
                + "Value".utf8
        )

        let decoded = try buffer.readFieldLine()
        #expect(decoded == .literal(requireLiteralRepresentation: true, name: "Name", value: "Value"))
    }
}
