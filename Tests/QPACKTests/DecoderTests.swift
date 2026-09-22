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
import Testing

@_spi(PackageInternal) @testable import QPACK

struct DecoderTests {
    @Test
    func decodeLiteral() throws {
        let line = FieldLine.literal(requireLiteralRepresentation: false, name: "hello", value: "World")
        let fields = try QPACKDecoder().decodeFieldSection(.init(prefix: .staticOnly, lines: [line]))

        #expect(fields == [HTTPField(name: .init("Hello")!, value: "World")])
    }

    @Test
    func decodeInvalidLiteralName() {
        let line = FieldLine.literal(requireLiteralRepresentation: false, name: "Hello", value: "World")
        #expect(throws: QPACKDecoderError.invalidHeaderName) {
            try QPACKDecoder().decodeFieldSection(.init(prefix: .staticOnly, lines: [line]))
        }
    }

    @Test
    func decodeIndexedStatic() throws {
        let line = FieldLine.indexed(.staticTable, index: 46)
        let fields = try QPACKDecoder().decodeFieldSection(.init(prefix: .staticOnly, lines: [line]))

        #expect(fields == [HTTPField(name: .init("content-type")!, value: "application/json")])
    }

    @Test
    func decodeIndexedStaticPseudo() throws {
        let line = FieldLine.indexed(.staticTable, index: 17)
        let fields = try QPACKDecoder().decodeFieldSection(.init(prefix: .staticOnly, lines: [line]))

        #expect(fields == [HTTPField(name: .init(parsed: ":method")!, value: "GET")])
    }

    @Test
    func decodeLiteralValueIndexedNameStatic() throws {
        let line = FieldLine.literalWithNameReference(
            requireLiteralRepresentation: true,
            table: .staticTable,
            index: 46,
            value: "image/png"
        )
        let fields = try QPACKDecoder().decodeFieldSection(.init(prefix: .staticOnly, lines: [line]))

        #expect(fields == [HTTPField(name: .contentType, value: "image/png")])
    }

    @Test
    func decodeMultipleLines() throws {
        let lines: [FieldLine] = [
            .indexed(.staticTable, index: 17),
            .literalWithNameReference(
                requireLiteralRepresentation: false,
                table: .staticTable,
                index: 46,
                value: "image/png"
            ),
            .literal(requireLiteralRepresentation: false, name: "hello", value: "World"),
        ]
        let fields = try QPACKDecoder().decodeFieldSection(.init(prefix: .staticOnly, lines: lines))

        #expect(
            fields == [
                HTTPField(name: .init(parsed: ":method")!, value: "GET"),
                HTTPField(name: .contentType, value: "image/png"),
                HTTPField(name: .init("hello")!, value: "World"),
            ]
        )
    }

    @Test
    func decodeIndexedStaticInvalidRef() {
        #expect(throws: QPACKDecoderError.invalidReference) {
            try QPACKDecoder().decodeFieldSection(
                .init(prefix: .staticOnly, lines: [.indexed(.staticTable, index: 10000)])
            )
        }
    }

    @Test
    func decodeIndexedStaticNameReferenceInvalid() {
        let line = FieldLine.literalWithNameReference(
            requireLiteralRepresentation: false,
            table: .staticTable,
            index: 10000,
            value: "hi"
        )
        #expect(throws: QPACKDecoderError.invalidReference) {
            try QPACKDecoder().decodeFieldSection(.init(prefix: .staticOnly, lines: [line]))
        }
    }

    // MARK: Dynamic table references

    /// The dynamic table is always empty, so every way of referring to it is out of range.
    @Test(arguments: [
        FieldLine.indexed(.dynamicTable, index: 0),
        FieldLine.literalWithNameReference(
            requireLiteralRepresentation: false,
            table: .dynamicTable,
            index: 0,
            value: "hi"
        ),
        FieldLine.indexedWithPostBase(index: 0),
        FieldLine.literalWithNameReferenceWithPostBase(
            requireLiteralRepresentation: false,
            index: 0,
            value: "hi"
        ),
    ])
    func decodeDynamicTableReference(line: FieldLine) {
        #expect(throws: QPACKDecoderError.invalidReference) {
            try QPACKDecoder().decodeFieldSection(.init(prefix: .staticOnly, lines: [line]))
        }
    }

    /// A non-zero Required Insert Count cannot have been produced by a conformant encoder against an empty
    /// dynamic table.
    @Test
    func decodeNonZeroRequiredInsertCount() {
        let prefix = EncodedFieldSectionPrefix(encodedRequiredInsertCount: 2, deltaBase: 0, signBit: false)
        #expect(throws: QPACKDecoderError.invalidFieldSection) {
            try QPACKDecoder().decodeFieldSection(
                .init(prefix: prefix, lines: [.indexed(.staticTable, index: 17)])
            )
        }
    }

    /// RFC 9204 § 4.5.1.2: a Sign bit of 1 is invalid when the Required Insert Count is at most the Delta
    /// Base, which it always is here because the Required Insert Count is always zero.
    @Test
    func decodeNegativeBase() {
        let prefix = EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: true)
        #expect(throws: QPACKDecoderError.invalidFieldSection) {
            try QPACKDecoder().decodeFieldSection(
                .init(prefix: prefix, lines: [.indexed(.staticTable, index: 17)])
            )
        }
    }

    /// A non-zero Base is legal — the peer may have a dynamic table even though we never reference it — so
    /// long as no field line actually refers to the dynamic table.
    @Test
    func decodeNonZeroBase() throws {
        let prefix = EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 4, signBit: false)
        let fields = try QPACKDecoder().decodeFieldSection(
            .init(prefix: prefix, lines: [.indexed(.staticTable, index: 17)])
        )
        #expect(fields == [HTTPField(name: .init(parsed: ":method")!, value: "GET")])
    }
}
