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

import HTTPTypes
import NIOCore
import Testing

@_spi(PackageInternal) @testable import QPACK

struct EndToEndTests {
    /// Example RFC 9204 Appendix B.1. Literal Field Line with Name Reference.
    @available(anyAppleOS 26.0, *)
    @Test func literalFieldLineWithNameReference() throws {
        var stream0 = ByteBuffer()
        stream0.writeBytes([
            0x0, 0x0,  // Required Insert Count = 0, Base = 0
            // Literal Field Line with Name Reference, Static Table, Index=1 (:path=/index.html)
            0x51, 0x0b, 0x2f, 0x69, 0x6e, 0x64, 0x65, 0x78, 0x2e, 0x68, 0x74, 0x6d, 0x6c,
        ])

        let fieldSection = try #require(try stream0.readFieldSection())
        let decoded = try QPACKDecoder().decodeFieldSection(fieldSection)

        #expect(decoded.count == 1)
        #expect(decoded.first?.name.canonicalName == ":path")
        #expect(decoded.first?.value == "/index.html")
    }

    /// A field section which references the dynamic table cannot be decoded, because this implementation
    /// advertises a dynamic table capacity of zero and so the table is always empty.
    ///
    /// The bytes are RFC 9204 Appendix B.2's encoded field section on stream 4.
    @available(anyAppleOS 26.0, *)
    @Test func dynamicTableReferenceIsRejected() throws {
        var stream4 = ByteBuffer()
        stream4.writeBytes([
            // Required Insert Count = 2, Base = 0
            0x03, 0x81,
            // Indexed Field Line With Post-Base Index, Absolute Index = Base(0) + Index(0) = 0
            0x10,
            // Indexed Field Line With Post-Base Index, Absolute Index = Base(0) + Index(1) = 1
            0x11,
        ])

        let fieldSection = try #require(try stream4.readFieldSection())
        #expect(throws: QPACKDecoderError.invalidFieldSection) {
            try QPACKDecoder().decodeFieldSection(fieldSection)
        }
    }

    /// A zero Required Insert Count with a dynamic table field line is still a reference to an empty table.
    @available(anyAppleOS 26.0, *)
    @Test func indexedDynamicTableFieldLineIsRejected() throws {
        var stream = ByteBuffer()
        stream.writeBytes([
            0x00, 0x00,  // Required Insert Count = 0, Base = 0
            0x80,  // Indexed Field Line, Dynamic Table, Relative Index = 0
        ])

        let fieldSection = try #require(try stream.readFieldSection())
        #expect(throws: QPACKDecoderError.invalidReference) {
            try QPACKDecoder().decodeFieldSection(fieldSection)
        }
    }

    /// Everything the encoder produces must round-trip through the decoder.
    @available(anyAppleOS 26.0, *)
    @Test func roundTrip() throws {
        let fields: [HTTPField] = [
            .init(name: .init(parsed: ":method")!, value: "GET"),  // exact static table match
            .init(name: .init(parsed: ":path")!, value: "/index.html"),  // static table name match
            .init(name: .init("x-custom")!, value: "value"),  // literal
        ]

        let encoded = QPACKEncoder().encode(headers: fields)

        var buffer = ByteBuffer()
        buffer.writeFieldSectionPrefix(encoded.prefix)
        for line in encoded.lines {
            buffer.writeFieldLine(line, preferHuffmanEncoding: true)
        }

        let readBack = try #require(try buffer.readFieldSection())
        #expect(try QPACKDecoder().decodeFieldSection(readBack) == fields)
    }
}
