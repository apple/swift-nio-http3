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

    static let nonPseudoHeaders = HTTPFields(Self.headers.filter { !$0.name.rawName.hasPrefix(":") })

    @available(anyAppleOS 27, *)
    @Test(arguments: [true, false])
    func writesItsFieldSection(preferHuffmanEncoding: Bool) throws {
        let encoder = StaticQPACKEncoder()
        let (buffer, _) = encodeWithExactRoom(encoder.maxEncodedLength(of: Self.headers)) {
            encoder.encode(fields: Self.headers, into: &$0, preferHuffmanEncoding: preferHuffmanEncoding)
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

    /// Requests with every combination of pseudo header fields: an absolute URI, an `*` path, CONNECT and Extended
    /// CONNECT, and pseudo header fields whose length takes more than one byte.
    static var requests: [HTTPRequest] {
        var post = HTTPRequest(method: .post, scheme: "https", authority: "www.example.com", path: "/upload")
        post.headerFields = Self.nonPseudoHeaders
        let options = HTTPRequest(method: .options, scheme: "https", authority: "www.example.com", path: "*")
        let connect = HTTPRequest(method: .connect, scheme: nil, authority: "www.example.com:443", path: nil)
        var extendedConnect = HTTPRequest(method: .connect, scheme: "https", authority: "example.com", path: "/chat")
        extendedConnect.extendedConnectProtocol = "websocket"
        let long = HTTPRequest(
            method: .get,
            scheme: "https",
            authority: String(repeating: "a", count: 200) + ".example.com",
            path: "/" + String(repeating: "b", count: 300)
        )
        return [post, options, connect, extendedConnect, long]
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.requests, [true, false])
    func writesTheFieldSectionOfARequest(request: HTTPRequest, preferHuffmanEncoding: Bool) {
        let encoder = StaticQPACKEncoder()
        let (buffer, _) = encodeWithExactRoom(encoder.maxEncodedLength(of: request)) {
            encoder.encode(request: request, into: &$0, preferHuffmanEncoding: preferHuffmanEncoding)
        }

        // The pseudo header fields come first (RFC 9114 § 4.3).
        let pseudo = request.pseudoHeaderFields
        let fields =
            [pseudo.method, pseudo.scheme, pseudo.authority, pseudo.path, pseudo.extendedConnectProtocol]
            .compactMap { $0 } + Array(request.headerFields)
        #expect(buffer == Self.encode(fields, preferHuffmanEncoding: preferHuffmanEncoding))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.requests, [true, false])
    func requestRoundTripsThroughTheDecoder(request: HTTPRequest, preferHuffmanEncoding: Bool) throws {
        let encoder = StaticQPACKEncoder()
        let (buffer, _) = encodeWithExactRoom(encoder.maxEncodedLength(of: request)) {
            encoder.encode(request: request, into: &$0, preferHuffmanEncoding: preferHuffmanEncoding)
        }

        let fields = try Self.decode(buffer)
        let pseudo = request.pseudoHeaderFields
        let expected =
            [pseudo.method, pseudo.scheme, pseudo.authority, pseudo.path, pseudo.extendedConnectProtocol]
            .compactMap { $0 } + Array(request.headerFields)
        #expect(fields.map(\.name) == expected.map(\.name))
        #expect(fields.map(\.value) == expected.map(\.value))
    }

    /// Statuses which are in the static table, and some which aren't (RFC 9204 Appendix A).
    static var statuses: [HTTPResponse.Status] {
        [.ok, .earlyHints, .notFound, .serviceUnavailable, 418, 599]
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.statuses, [true, false])
    func writesTheFieldSectionOfAResponse(status: HTTPResponse.Status, preferHuffmanEncoding: Bool) throws {
        var response = HTTPResponse(status: status)
        response.headerFields = Self.nonPseudoHeaders
        let encoder = StaticQPACKEncoder()
        let (buffer, _) = encodeWithExactRoom(encoder.maxEncodedLength(of: response)) {
            encoder.encode(response: response, into: &$0, preferHuffmanEncoding: preferHuffmanEncoding)
        }

        let fields = [response.pseudoHeaderFields.status] + Array(response.headerFields)
        #expect(buffer == Self.encode(fields, preferHuffmanEncoding: preferHuffmanEncoding))

        let decoded = try Self.decode(buffer)
        #expect(decoded.map(\.name) == fields.map(\.name))
        #expect(decoded.map(\.value) == fields.map(\.value))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: [true, false])
    func writesTheFieldSectionOfTrailers(preferHuffmanEncoding: Bool) {
        let trailers = Self.nonPseudoHeaders
        let encoder = StaticQPACKEncoder()
        let (buffer, _) = encodeWithExactRoom(encoder.maxEncodedLength(of: trailers)) {
            encoder.encode(fields: trailers, into: &$0, preferHuffmanEncoding: preferHuffmanEncoding)
        }

        #expect(buffer == Self.encode(Array(trailers), preferHuffmanEncoding: preferHuffmanEncoding))
    }

    @available(anyAppleOS 27, *)
    @Test func writesNothingButThePrefixForNoTrailers() {
        let encoder = StaticQPACKEncoder()
        let (buffer, _) = encodeWithExactRoom(encoder.maxEncodedLength(of: HTTPFields())) {
            encoder.encode(fields: HTTPFields(), into: &$0, preferHuffmanEncoding: true)
        }
        #expect(Array(buffer.readableBytesView) == [0, 0])
    }

    /// Decodes `buffer`, a field section which references no dynamic table entries, with the decoder of the
    /// channel based stack.
    @available(anyAppleOS 27, *)
    static func decode(_ buffer: ByteBuffer) throws -> [HTTPField] {
        var buffer = buffer
        let encodedPrefix = try #require(try buffer.readFieldSectionPrefix())
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 0)
        let prefix = try #require(decoder.decodeFieldSectionPrefix(encodedPrefix))
        guard
            case .success(let fields, nil) = decoder.decodeFieldSection(
                prefix: prefix,
                lines: buffer,
                streamID: 0
            )
        else {
            Issue.record("The field section couldn't be decoded")
            return []
        }
        return fields
    }

    /// The field section of `fields`, as
    /// ``StaticQPACKEncoder/encode(fields:into:preferHuffmanEncoding:)-([HTTPField],_,_)`` writes it.
    @available(anyAppleOS 27, *)
    static func encode(_ fields: [HTTPField], preferHuffmanEncoding: Bool) -> ByteBuffer {
        let encoder = StaticQPACKEncoder()
        return encodeWithExactRoom(encoder.maxEncodedLength(of: fields)) {
            encoder.encode(fields: fields, into: &$0, preferHuffmanEncoding: preferHuffmanEncoding)
        }.0
    }

    @available(anyAppleOS 27, *)
    @Test func writesNothingButThePrefixForNoFields() {
        let encoder = StaticQPACKEncoder()
        let (buffer, _) = encodeWithExactRoom(encoder.maxEncodedLength(of: [])) {
            encoder.encode(fields: [], into: &$0, preferHuffmanEncoding: true)
        }
        // Required Insert Count 0, then Base 0
        #expect(Array(buffer.readableBytesView) == [0, 0])
    }
}
