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
@_spi(PackageInternal) import QPACK
import Testing

struct EncodeDecodeTests {
    /// A field which the static table doesn't cover is sent as a literal.
    @Test
    func encodeLiteral() throws {
        try self.testEncodeDecodeRoundtrip(
            fields: [.init(name: .init("hello")!, value: "world")]
        )
    }

    /// The field matches exactly a static table entry. We should reference that.
    @Test
    func encodeStaticTable() throws {
        try self.testEncodeDecodeRoundtrip(
            fields: [.init(name: .accept, value: "*/*")]
        )
    }

    /// The field name matches a static table entry but the value does not.
    /// So we should refer to the name from the static table and send the value literally.
    @Test
    func encodeStaticTableNameReference() throws {
        try self.testEncodeDecodeRoundtrip(
            fields: [.init(name: .accept, value: "blabla")]
        )
    }

    /// Sending various fields, some of which match static table entries, some which are partial matches,
    /// and some which aren't in the table at all.
    @Test
    func encodeMultipleFields() throws {
        try self.testEncodeDecodeRoundtrip(
            fields: [
                .init(name: .init("test1")!, value: "a"),  // no match
                .init(name: .init("test1")!, value: "b"),  // no match
                .init(name: .init("authorization")!, value: "c"),  // name match to static table 84
                .init(name: .init("vary")!, value: "origin"),  // full match static table index 60
                .init(name: .init("test2")!, value: "a"),  // no match
            ]
        )
    }

    private func testEncodeDecodeRoundtrip(
        fields: [HTTPField],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let encoded = QPACKEncoder().encode(headers: fields)
        let decoded = try QPACKDecoder().decodeFieldSection(encoded)
        #expect(decoded == fields, sourceLocation: sourceLocation)
    }
}
