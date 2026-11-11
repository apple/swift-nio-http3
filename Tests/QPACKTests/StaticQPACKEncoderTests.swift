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

/// Tests that the static encoder writes the field sections it describes into an `OutputRawSpan`, within the room it
/// asks for.
struct StaticQPACKEncoderTests {
    /// Exact static matches, name only matches, fields absent from the static table, a never indexed field, values
    /// whose length takes more than one byte, and values which are shorter without Huffman coding.
    static let headers: [HTTPField] = {
        var neverIndexed = HTTPField(name: .authorization, value: "Bearer secret")
        neverIndexed.indexingStrategy = .disallow
        return [
            HTTPField(name: .init(parsed: ":method")!, value: "GET"),
            HTTPField(name: .init(parsed: ":scheme")!, value: "https"),
            HTTPField(name: .init(parsed: ":authority")!, value: "www.example.com"),
            HTTPField(name: .init(parsed: ":path")!, value: "/" + String(repeating: "a", count: 300)),
            HTTPField(name: .accept, value: "*/*"),
            HTTPField(name: .init("x-custom-header")!, value: "some-custom-value"),
            HTTPField(name: .init("x-unicode")!, value: "héllo wörld ✓ 🎉"),
            HTTPField(name: .init("x-empty")!, value: ""),
            neverIndexed,
        ]
    }()

    @available(anyAppleOS 27, *)
    @Test(arguments: [true, false])
    func writesItsFieldSection(preferHuffmanEncoding: Bool) throws {
        let encoder = StaticQPACKEncoder()
        let (buffer, _) = encodeWithExactRoom(encoder.maxEncodedLength(of: Self.headers)) {
            encoder.encode(headers: Self.headers, into: &$0, preferHuffmanEncoding: preferHuffmanEncoding)
        }

        let expected = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
            lines: [
                .indexed(.staticTable, index: 17),
                .indexed(.staticTable, index: 23),
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 0,
                    value: "www.example.com"
                ),
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 1,
                    value: "/" + String(repeating: "a", count: 300)
                ),
                .indexed(.staticTable, index: 29),
                .literal(requireLiteralRepresentation: false, name: "x-custom-header", value: "some-custom-value"),
                .literal(requireLiteralRepresentation: false, name: "x-unicode", value: "héllo wörld ✓ 🎉"),
                .literal(requireLiteralRepresentation: false, name: "x-empty", value: ""),
                .literalWithNameReference(
                    requireLiteralRepresentation: true,
                    table: .staticTable,
                    index: 84,
                    value: "Bearer secret"
                ),
            ]
        )
        #expect(FieldSection(readingAll: buffer) == expected)
        // Comparing bytes too checks the Huffman coding, which reading undoes.
        #expect(buffer == expected.bytes(preferHuffmanEncoding: preferHuffmanEncoding))
    }

    @available(anyAppleOS 27, *)
    @Test func writesNothingButThePrefixForNoFields() {
        let encoder = StaticQPACKEncoder()
        let (buffer, _) = encodeWithExactRoom(encoder.maxEncodedLength(of: [])) {
            encoder.encode(headers: [], into: &$0, preferHuffmanEncoding: true)
        }
        // Required Insert Count 0, then Base 0
        #expect(Array(buffer.readableBytesView) == [0, 0])
    }
}
