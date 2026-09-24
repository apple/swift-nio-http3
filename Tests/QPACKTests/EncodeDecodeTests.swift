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
import NIOQUICHelpers
@_spi(PackageInternal) import QPACK
import Testing

struct EncodeDecodeTests {
    /// Dynamic table is disabled, literal should be sent as a literal.
    @Test
    func encodeLiteral() {
        self.testEncodeDecodeRoundtripNoDynamic(
            fields: [.init(name: .init("hello")!, value: "world")]
        )
    }

    /// Dynamic table is enabled, literal should be added to the table then a reference to the table sent.
    @Test
    func encodeLiteralAddingToTable() throws {
        try self.testEncodeDecodeRoundtripWithDynamic(
            fields: [.init(name: .init("hello")!, value: "world")],
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000
        )
    }

    /// Dynamic table is enabled but has no capacity, literal should be sent as a literal.
    @Test
    func encodeLiteralTableFull() throws {
        try self.testEncodeDecodeRoundtripWithDynamic(
            fields: [.init(name: .init("hello")!, value: "world")],
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 0
        )
    }

    /// Dynamic table is enabled, literal should be added to the table then a reference to the table sent.
    /// Further literals are either identical or share a name so should send same references without further inserts.
    /// No literals should be sent in field section.
    @Test
    func encodeLiteralAddingToTableWithReuse() throws {
        try self.testEncodeDecodeRoundtripWithDynamic(
            fields: [
                .init(name: .init("hello")!, value: "world"),
                .init(name: .init("hello")!, value: "earth"),
                .init(name: .init("hello")!, value: "world"),
            ],
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000
        )
    }

    /// The field matches exactly a static table entry. We should reference that. No instructions should be sent.
    /// That is regardless of dynamic table being available.
    @Test
    func encodeStaticTable() throws {
        try self.testEncodeDecodeRoundtripWithDynamic(
            fields: [
                .init(name: .accept, value: "*/*")
            ],
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000
        )
        self.testEncodeDecodeRoundtripNoDynamic(
            fields: [
                .init(name: .accept, value: "*/*")
            ]
        )
    }

    /// The field name matches a static table entry but the value does not. Dynamic table is disabled.
    /// So we should refer to the name from the static table and send the value literally.
    @Test
    func encodeStaticTableNameReference() {
        self.testEncodeDecodeRoundtripNoDynamic(
            fields: [.init(name: .accept, value: "blabla")]
        )
    }

    /// The field name matches a static table entry but the value does not. Dynamic table is enabled.
    /// We'll send a insert instruction by referencing the name from the static table.
    /// Then we'll send a reference to the newly inserted entry.
    @Test
    func encodeStaticTableNameReferenceWithDynamic() throws {
        try self.testEncodeDecodeRoundtripWithDynamic(
            fields: [.init(name: .accept, value: "blabla")],
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000
        )
    }

    /// Sending various fields, some of which match static table entries, some which need to be added to dynamic table,
    /// some which already exist in dynamic table, some which are partial matches to static/dynamic table.
    @Test
    func encodeMultipleInserts() throws {
        try self.testEncodeDecodeRoundtripWithDynamic(
            fields: [
                .init(name: .init("test1")!, value: "a"),  // no match. insert it as index 0
                .init(name: .init("test1")!, value: "b"),  // name match to dynamic table index 0
                .init(name: .init("authorization")!, value: "c"),  // name match to static table 84. Insert as index 1
                .init(name: .init("test1")!, value: "a"),  // full match to dynamic table index 0
                .init(name: .init("vary")!, value: "origin"),  // full match static table index 60
                .init(name: .init("test2")!, value: "a"),  // no match. insert it as index 2
                .init(name: .init("authorization")!, value: "c"),  // full match to dynamic table index 1
            ],
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000
        )
    }

    private func testEncodeDecodeRoundtripNoDynamic(
        fields: [HTTPField],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 0)

        let encoder = StaticQPACKEncoder()
        let encoded: FieldSection = encoder.encode(headers: fields)

        let decoded = decoder.decodeFieldSection(encoded, streamID: 1)

        switch decoded {
        case .success(let decodedFields, let instructions):
            #expect(decodedFields == fields, sourceLocation: sourceLocation)
            // Must be no instructions because no dynamic table
            #expect(instructions == nil, sourceLocation: sourceLocation)
        default:
            Issue.record("Unexpected result \(decoded)", sourceLocation: sourceLocation)
        }
    }

    private func testEncodeDecodeRoundtripWithDynamic(
        fields: [HTTPField],
        dynamicTableMaxCapacity: Int,
        dynamicTableInitialCapacity: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        var decoder = QPACKDecoder(
            dynamicTableMaxCapacity: dynamicTableMaxCapacity
        )

        var encoderInstructions = [QPACKEncoderInstruction]()
        var (encoder, instruction1) = DynamicQPACKEncoder.create(
            dynamicTableMaxCapacity: dynamicTableMaxCapacity,
            dynamicTableInitialCapacity: dynamicTableInitialCapacity,
            maxBlockedStreams: 100,  // We're not testing the max behaviour, so we set it high
            targetEvictableFraction: 0.1
        )
        if let instruction1 {
            encoderInstructions.append(instruction1)
        }

        let encoded = encoder.encode(headers: fields, forStream: 1)
        encoderInstructions.append(contentsOf: encoded.instructions)

        for instruction in encoderInstructions {
            _ = try decoder.processInstruction(instruction)
        }
        let decoded = decoder.decodeFieldSection(encoded.fieldSection, streamID: 1)

        switch decoded {
        case .success(let decodedFields, let decoderInstruction):
            #expect(decodedFields == fields, sourceLocation: sourceLocation)
            // feed back the instructions
            if let decoderInstruction {
                try encoder.processInstruction(decoderInstruction)
            }
        default:
            Issue.record("Unexpected result \(decoded)", sourceLocation: sourceLocation)
        }
    }
}

extension QPACKFullDecodeResult {
    func unwrap() throws -> ([HTTPField], QPACKDecoderInstruction?)? {
        switch self {
        case .missingInsertCount:
            return nil
        case .success(let result, let instruction):
            return (result, instruction)
        case .error(let error):
            throw error
        }
    }
}

extension QPACKDecoder {
    fileprivate mutating func decodeFieldSection(
        _ fieldSection: FieldSection,
        streamID: QUICStreamID
    ) -> QPACKFullDecodeResult {
        guard let prefix = self.decodeFieldSectionPrefix(fieldSection.prefix) else {
            return .error(QPACKDecoderError.invalidFieldSection)
        }
        return self.decodeFieldSection(prefix: prefix, lines: fieldSection.lines, streamID: streamID)
    }
}
