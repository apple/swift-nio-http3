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
        let bound = encoder.maxEncodedLength(of: Self.headers)
        var buffer = ByteBuffer(initialCapacity: bound) { output in
            encoder.encode(headers: Self.headers, into: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        }
        #expect(buffer.readableBytes <= bound)

        let decoded = try buffer.readFieldSection()
        #expect(buffer.readableBytes == 0)
        #expect(decoded == encoder.encode(headers: Self.headers))
    }

    @available(anyAppleOS 27, *)
    @Test func writesNothingButThePrefixForNoFields() {
        let encoder = StaticQPACKEncoder()
        let buffer = ByteBuffer(initialCapacity: encoder.maxEncodedLength(of: [])) { output in
            encoder.encode(headers: [], into: &output, preferHuffmanEncoding: true)
        }
        // Required Insert Count 0, then Base 0
        #expect(Array(buffer.readableBytesView) == [0, 0])
    }
}
