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

struct EncoderTests {
    /// A field which isn't in the static table at all is sent as a literal.
    @Test
    func encodeLiteral() {
        let encoder = QPACKEncoder()
        let encoded = encoder.encode(headers: [.init(name: .init("hello")!, value: "world")])
        let expect = FieldSection(
            prefix: .staticOnly,
            lines: [FieldLine.literal(requireLiteralRepresentation: false, name: "hello", value: "world")]
        )
        #expect(encoded == expect)
    }

    /// The field matches exactly a static table entry. We should reference that.
    @Test
    func encodeStaticTable() {
        let encoder = QPACKEncoder()
        let encoded = encoder.encode(headers: [.init(name: .accept, value: "*/*")])
        let expect = FieldSection(
            prefix: .staticOnly,
            lines: [FieldLine.indexed(.staticTable, index: 29)]
        )
        #expect(encoded == expect)
    }

    /// The field name matches a static table entry but the value does not.
    /// So we should refer to the name from the static table and send the value literally.
    @Test
    func encodeStaticTableNameReference() {
        let encoder = QPACKEncoder()
        let encoded = encoder.encode(headers: [.init(name: .accept, value: "blabla")])
        let expect = FieldSection(
            prefix: .staticOnly,
            lines: [
                FieldLine.literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 29,
                    value: "blabla"
                )
            ]
        )
        #expect(encoded == expect)
    }

    /// Every field of a multi-field section is encoded independently, and the prefix stays a zero
    /// Required Insert Count with a zero Base.
    @Test
    func encodeMultipleFields() {
        let encoder = QPACKEncoder()
        let encoded = encoder.encode(headers: [
            .init(name: .accept, value: "*/*"),
            .init(name: .accept, value: "blabla"),
            .init(name: .init("hello")!, value: "world"),
        ])
        let expect = FieldSection(
            prefix: .staticOnly,
            lines: [
                .indexed(.staticTable, index: 29),
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 29,
                    value: "blabla"
                ),
                .literal(requireLiteralRepresentation: false, name: "hello", value: "world"),
            ]
        )
        #expect(encoded == expect)
    }

    @Test
    func indexingStrategyWithStaticTableMatch() {
        // Only `.disallow` has any effect, because there is no dynamic table for the others to steer away
        // from. `.disallow` also requires intermediaries to retain the literal.
        for strategy in [HTTPField.DynamicTableIndexingStrategy.automatic, .prefer, .avoid] {
            self.assertEncodedAsLiteralWithNameReference(
                indexingStrategy: strategy,
                expectRequireLiteralRepresentation: false
            )
        }
        self.assertEncodedAsLiteralWithNameReference(
            indexingStrategy: .disallow,
            expectRequireLiteralRepresentation: true
        )
    }

    private func assertEncodedAsLiteralWithNameReference(
        indexingStrategy: HTTPField.DynamicTableIndexingStrategy,
        expectRequireLiteralRepresentation: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let encoder = QPACKEncoder()
        var header = HTTPField(name: .accept, value: "blabla")
        header.indexingStrategy = indexingStrategy
        let encoded = encoder.encode(headers: [header])
        let expect = FieldSection(
            prefix: .staticOnly,
            lines: [
                FieldLine.literalWithNameReference(
                    requireLiteralRepresentation: expectRequireLiteralRepresentation,
                    table: .staticTable,
                    index: 29,
                    value: "blabla"
                )
            ]
        )
        #expect(encoded == expect, sourceLocation: sourceLocation)
    }
}
