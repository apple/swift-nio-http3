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

struct EncoderTests {
    /// Dynamic table is disabled, literal should be sent as a literal.
    @Test
    func encodeLiteral() {
        let encoder = StaticQPACKEncoder()
        let encoded = encoder.encode(headers: [.init(name: .init("hello")!, value: "world")])
        let expect = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
            lines: [FieldLine.literal(requireLiteralRepresentation: false, name: "hello", value: "world")]
        )
        #expect(encoded == expect)
    }

    /// Dynamic table is enabled, literal should be added to the table then a reference to the table sent.
    @Test
    func encodeLiteralAddingToTable() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000,
            maxBlockedStreams: 100
        )
        let encoded = encoder.encode(headers: [.init(name: .init("hello")!, value: "world")], forStream: 1)
        let expect = FieldSection(
            // required insert count `1` is encoded as `2`
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 2, deltaBase: 0, signBit: true),
            lines: [FieldLine.indexedWithPostBase(index: 0)]
        )
        #expect(encoded.fieldSection == expect)
        #expect(encoded.instructions == [.insertWithLiteralName(name: "hello", value: "world")])
    }

    /// Dynamic table is enabled but has no capacity, literal should be sent as a literal.
    @Test
    func encodeLiteralTableFull() {
        // This max doesn't matter for this test, the current capacity is still 0
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 0,
            maxBlockedStreams: 100
        )
        // We enabled the dynamic table but the capacity is 0 (default) so we should get literals
        let encoded = encoder.encode(headers: [.init(name: .init("hello")!, value: "world")], forStream: 1)
        let expect = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
            lines: [FieldLine.literal(requireLiteralRepresentation: false, name: "hello", value: "world")]
        )
        #expect(encoded.fieldSection == expect)
        #expect(encoded.instructions == .init())
    }

    /// Dynamic table is enabled, literal should be added to the table then a reference to the table sent.
    /// Further literals are either identical or share a name so should send same references without further inserts.
    /// No literals should be sent in field section.
    @Test
    func encodeLiteralAddingToTableWithReuse() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000,
            maxBlockedStreams: 100
        )
        let encoded = encoder.encode(
            headers: [
                .init(name: .init("hello")!, value: "world"),
                .init(name: .init("hello")!, value: "earth"),
                .init(name: .init("hello")!, value: "world"),
            ],
            forStream: 1
        )
        let expect = FieldSection(
            // required insert count `1` is encoded as `2`
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 2, deltaBase: 0, signBit: true),
            lines: [
                .indexedWithPostBase(index: 0),
                .literalWithNameReferenceWithPostBase(requireLiteralRepresentation: false, index: 0, value: "earth"),
                .indexedWithPostBase(index: 0),
            ]
        )
        #expect(encoded.fieldSection == expect)
        #expect(encoded.instructions == [.insertWithLiteralName(name: "hello", value: "world")])
    }

    /// Dynamic table is enabled, literal should be added to the table then a reference to the table sent.
    /// Second literal shares a name so would normally send same references without further inserts.
    /// However, the encoder should choose not to reference the existing entry because we'll set the eviction strategy such
    /// that that entry is too old to be referenced.
    @Test
    func encodeLiteralAddingToTableWithReuseNotPossible() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            // enough for 3 entries where both entries are 5 (name) + 5 (value) + 32 (overhead), ie 42
            dynamicTableMaxCapacity: 42 * 3,
            dynamicTableInitialCapacity: 42 * 3,
            maxBlockedStreams: 100,
            // we want to force the encoder to not reference something even slightly old
            // Every entry becomes immediately un-referencable
            targetEvictableFraction: 0.99
        )
        let encoded = encoder.encode(
            headers: [
                .init(name: .init("hello")!, value: "world"),
                .init(name: .init("hello")!, value: "earth"),
                .init(name: .init("hello")!, value: "world"),
            ],
            forStream: 1
        )
        let prefix = FieldSectionPrefix(requiredInsertCount: 3, base: 0)
        let expect = FieldSection(
            prefix: prefix.encode(maxCapacity: 42 * 3),
            lines: [
                .indexedWithPostBase(index: 0),
                .indexedWithPostBase(index: 1),
                .indexedWithPostBase(index: 2),
            ]
        )
        #expect(encoded.fieldSection == expect)
        #expect(
            encoded.instructions
                == [
                    .insertWithLiteralName(name: "hello", value: "world"),
                    // Normally this would be a insert with dynamic table reference for the name (because it's "hello" again)
                    // But we made it that we can't reference anything even slightly old
                    .insertWithLiteralName(name: "hello", value: "earth"),
                    // This is a duplicate rather than a re-insert because we _can_ reference something old for duplication purposes
                    .duplicateEntry(relativeIndex: 1),
                ]
        )
    }

    /// Dynamic table is enabled, literal should be added to the table then a reference to the table sent.
    /// Second literal shares a name so would normally send same references without further inserts.
    /// However, the encoder should choose not to reference the existing entry because we'll set the eviction strategy such
    /// that that entry is too old to be referenced.
    /// Unlike the test above, the encoder also can't duplicate or reinsert due to limited space.
    /// So it is forced to use literals for sending the further headers.
    @Test
    func encodeLiteralAddingToTableWithReuseNotPossibleAndInsertNotPossible() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            // enough for 1 entry (5+5+32)
            dynamicTableMaxCapacity: 42,
            dynamicTableInitialCapacity: 42,
            maxBlockedStreams: 100,
            // we want to force the encoder to not reference something even slightly old
            // Every entry becomes immediately un-referencable
            targetEvictableFraction: 0.99
        )
        let encoded = encoder.encode(
            headers: [
                .init(name: .init("hello")!, value: "world"),
                .init(name: .init("hello")!, value: "earth"),
                .init(name: .init("hello")!, value: "world"),
            ],
            forStream: 1
        )
        let prefix = FieldSectionPrefix(requiredInsertCount: 1, base: 0)
        let expect = FieldSection(
            prefix: prefix.encode(maxCapacity: 42),
            lines: [
                .indexedWithPostBase(index: 0),
                // Further headers sent as literals because referencing and inserting are both impossible now
                .literal(requireLiteralRepresentation: false, name: "hello", value: "earth"),
                .literal(requireLiteralRepresentation: false, name: "hello", value: "world"),
            ]
        )
        #expect(encoded.fieldSection == expect)
        #expect(encoded.instructions == [.insertWithLiteralName(name: "hello", value: "world")])
    }

    /// The field matches exactly a static table entry. We should reference that. No instructions should be sent.
    @Test
    func encodeStaticTable() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000,
            maxBlockedStreams: 100
        )
        let encoded = encoder.encode(headers: [.init(name: .accept, value: "*/*")], forStream: 1)
        let expect = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
            lines: [FieldLine.indexed(.staticTable, index: 29)]
        )
        #expect(encoded.fieldSection == expect)
        #expect(encoded.instructions == .init())
    }

    /// The field matches exactly a static table entry. We should reference that. No instructions should be sent.
    /// This is despite the dynamic table being enabled, no need to insert when we have it in static table already.
    @Test
    func encodeStaticTableDespiteDynamic() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000,
            maxBlockedStreams: 100
        )
        let encoded = encoder.encode(headers: [.init(name: .accept, value: "*/*")], forStream: 1)
        let expect = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
            lines: [FieldLine.indexed(.staticTable, index: 29)]
        )
        #expect(encoded.fieldSection == expect)
        #expect(encoded.instructions == .init())
    }

    /// The field name matches a static table entry but the value does not. Dynamic table is disabled.
    /// So we should refer to the name from the static table and send the value literally.
    @Test
    func encodeStaticTableNameReference() {
        let encoder = StaticQPACKEncoder()
        let encoded = encoder.encode(headers: [.init(name: .accept, value: "blabla")])
        let expect = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
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

    /// The field name matches a static table entry but the value does not. Dynamic table is enabled.
    /// We'll send a insert instruction by referencing the name from the static table.
    /// Then we'll send a reference to the newly inserted entry.
    @Test
    func encodeStaticTableNameReferenceWithDynamic() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000,
            maxBlockedStreams: 100
        )
        let encoded = encoder.encode(headers: [.init(name: .accept, value: "blabla")], forStream: 1)
        let expect = FieldSection(
            // required insert count `1` is encoded as `2`
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 2, deltaBase: 0, signBit: true),
            lines: [
                .indexedWithPostBase(index: 0)
            ]
        )
        #expect(encoded.fieldSection == expect)
        #expect(encoded.instructions == [.insertWithNameReference(.staticTable, relativeIndex: 29, value: "blabla")])
    }

    /// The field name matches a static table entry but the value does not. Dynamic table is enabled but can't fit the value.
    /// So we should refer to the name from the static table and send the value literally.
    @Test
    func encodeStaticTableNameReferenceDynamicTableFull() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1,
            dynamicTableInitialCapacity: 1,
            maxBlockedStreams: 100
        )
        let encoded = encoder.encode(headers: [.init(name: .accept, value: "blabla")], forStream: 1)
        let expect = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
            lines: [
                FieldLine.literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 29,
                    value: "blabla"
                )
            ]
        )
        #expect(encoded.fieldSection == expect)
        #expect(encoded.instructions == .init())
    }

    /// Sending various fields, some of which match static table entries, some which need to be added to dynamic table,
    /// some which already exist in dynamic table, some which are partial matches to static/dynamic table.
    @Test
    func encodeMultipleInserts() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000,
            maxBlockedStreams: 100
        )
        let encoded = encoder.encode(
            headers: [
                .init(name: .init("test1")!, value: "a"),  // no match. insert it as index 0
                .init(name: .init("test1")!, value: "b"),  // name match to dynamic table index 0
                .init(name: .init("authorization")!, value: "c"),  // name match to static table 84. Insert as index 1
                .init(name: .init("test1")!, value: "a"),  // full match to dynamic table index 0
                .init(name: .init("vary")!, value: "origin"),  // full match static table index 60
                .init(name: .init("test2")!, value: "a"),  // no match. insert it as index 2
                .init(name: .init("authorization")!, value: "c"),  // full match to dynamic table index 1
            ],
            forStream: 1
        )
        let base = 0
        let expect = FieldSection(
            // required insert count `3` is encoded as `4`. Base is 0 encoded as a delta
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 4, deltaBase: 3 - base - 1, signBit: true),
            lines: [
                .indexedWithPostBase(index: 0 - base),  // absolute idx 0
                .literalWithNameReferenceWithPostBase(
                    requireLiteralRepresentation: false,
                    index: 0 - base,  // absolute idx 0
                    value: "b"
                ),
                .indexedWithPostBase(index: 1 - base),  // absolute idx 1
                .indexedWithPostBase(index: 0 - base),  // absolute idx 0
                .indexed(.staticTable, index: 60),
                .indexedWithPostBase(index: 2 - base),  // absolute idx 2
                .indexedWithPostBase(index: 1 - base),  // absolute idx 1
            ]
        )
        #expect(encoded.fieldSection == expect)
        #expect(
            encoded.instructions
                == [
                    .insertWithLiteralName(name: "test1", value: "a"),
                    .insertWithNameReference(.staticTable, relativeIndex: 84, value: "c"),
                    .insertWithLiteralName(name: "test2", value: "a"),
                ]
        )
    }

    /// Encode some header, then separately encode it again.
    /// The base will be different the second time.
    @Test
    func multipleEncodes() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 1000,
            maxBlockedStreams: 100
        )
        let firstEncoded = encoder.encode(
            headers: [.init(name: .init("hello")!, value: "world")],
            forStream: 1
        )
        let firstExpect = FieldSection(
            // required insert count `1` is encoded as `2`
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 2, deltaBase: 0, signBit: true),
            lines: [FieldLine.indexedWithPostBase(index: 0)]
        )
        let secondEncoded = encoder.encode(
            headers: [.init(name: .init("hello")!, value: "world")],
            forStream: 1
        )
        let secondExpect = FieldSection(
            // required insert count `1` is encoded as `2`. Base is now 1, encoded as delta 0
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 2, deltaBase: 0, signBit: false),
            lines: [FieldLine.indexed(.dynamicTable, index: 0)]
        )
        #expect(firstEncoded.fieldSection == firstExpect)
        #expect(secondEncoded.fieldSection == secondExpect)
        #expect(firstEncoded.instructions == [.insertWithLiteralName(name: "hello", value: "world")])
        #expect(secondEncoded.instructions == [])
    }

    @Test
    func ackSectionWhichDidntUseTable() {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 100,
            dynamicTableInitialCapacity: 100,
            maxBlockedStreams: 100
        )
        // We will encode headers on stream 1, but will make it match a static table entry
        // That means the dynamic table doesn't get used, so the decoder should not send an ack
        // Receiving an ack on this stream is therefore an error
        let encoded = encoder.encode(
            headers: [.init(name: .init(parsed: ":status")!, value: "100")],
            forStream: 1
        ).fieldSection
        #expect(encoded.prefix.decode(totalInserts: 0, maxCapacity: 100)?.requiredInsertCount == 0)
        #expect(encoded.lines == [.indexed(.staticTable, index: 63)])
        #expect(throws: QPACKEncoderError.unexpectedStreamAck) {
            try encoder.processInstruction(.sectionAcknowledgement(streamID: 1))
        }
    }

    @Test
    func doubleSectionAck() throws {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 100,
            dynamicTableInitialCapacity: 100,
            maxBlockedStreams: 100
        )
        // We will encode headers on stream 1, which will make it use the dynamic table
        let encoded = encoder.encode(headers: [.init(name: .init("something")!, value: "test")], forStream: 1)
            .fieldSection
        #expect(encoded.prefix.decode(totalInserts: 1, maxCapacity: 100)?.requiredInsertCount == 1)
        #expect(encoded.lines == [.indexedWithPostBase(index: 0)])
        // One ack is normal and not an error
        try encoder.processInstruction(.sectionAcknowledgement(streamID: 1))
        // A second ack is extra and must be an error (RFC 9204 § 4.4.1)
        #expect(throws: QPACKEncoderError.unexpectedStreamAck) {
            try encoder.processInstruction(.sectionAcknowledgement(streamID: 1))
        }
    }

    /// Ensure we cannot remove unevictable entries when another stream is using it.
    @Test
    func multipleStreamEviction() throws {
        let maxCapacity = 100
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: maxCapacity,
            dynamicTableInitialCapacity: 35,
            maxBlockedStreams: 100,
            targetEvictableFraction: 0.0  // For predictability in the test
        )
        // used 32 + 1 + 1 = 34 bytes
        let encoded1 = encoder.encode(headers: [.init(name: .init("a")!, value: "1")], forStream: 1)
            .fieldSection
        #expect(encoded1.lines.first == .indexedWithPostBase(index: 0))
        #expect(encoded1.prefix.decode(totalInserts: 2, maxCapacity: maxCapacity)?.requiredInsertCount == 1)

        // Another stream now cannot add anything to the dynamic table because there's not enough space
        // And it can't make space because stream 1 hasn't been acked, so the existing entry can't be removed
        // So it should produce a literal instead
        let encoded2 = encoder.encode(headers: [.init(name: .init("b")!, value: "1")], forStream: 2)
            .fieldSection
        #expect(encoded2.lines.first == .literal(requireLiteralRepresentation: false, name: "b", value: "1"))

        // A third stream can refer to the same dynamic table entry, because it's already there
        // This also increases the ref count
        let encoded3 = encoder.encode(headers: [.init(name: .init("a")!, value: "1")], forStream: 3)
            .fieldSection
        #expect(encoded3.lines.first == .indexed(.dynamicTable, index: 0))
        #expect(encoded3.prefix.decode(totalInserts: 2, maxCapacity: maxCapacity)?.requiredInsertCount == 1)

        // Now, even if we ack stream 1, we still can't evict, because stream 3 also wants this entry
        try encoder.processInstruction(.sectionAcknowledgement(streamID: 1))

        // Ensure we cannot evict even now. So a new stream will still create a literal
        let encoded4 = encoder.encode(headers: [.init(name: .init("c")!, value: "1")], forStream: 4)
            .fieldSection
        #expect(encoded4.lines.first == .literal(requireLiteralRepresentation: false, name: "c", value: "1"))

        // Now ack stream 3
        try encoder.processInstruction(.sectionAcknowledgement(streamID: 3))

        // Now the table becomes purgeable and a new stream can add a new entry
        let encoded5 = encoder.encode(headers: [.init(name: .init("d")!, value: "1")], forStream: 1)
            .fieldSection
        #expect(encoded5.lines.first == .indexedWithPostBase(index: 0))
        #expect(encoded5.prefix.decode(totalInserts: 2, maxCapacity: maxCapacity)?.requiredInsertCount == 2)
    }

    @Test
    func avoidUsingEntriesNearingEviction() throws {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 330,
            dynamicTableInitialCapacity: 330,
            maxBlockedStreams: 100,
            targetEvictableFraction: 0.5
        )
        // We will add 7 entries, each has a length of 33
        // The total capacity is 330 which could store 10 such entries
        for i in 1...7 {
            let encoded = encoder.encode(headers: [.init(name: .init("\(i)")!, value: "")], forStream: 1)
            #expect(encoded.instructions == [.insertWithLiteralName(name: "\(i)", value: "")])
            #expect(encoded.fieldSection.lines.first == .indexedWithPostBase(index: 0))
            // Ack it, to drop the reference
            try encoder.processInstruction(.sectionAcknowledgement(streamID: 1))
        }
        // Target evictable is 0.5 which means only the newest 5 are not 'nearing eviction'
        // Now if we try to encode a field referencing one of the 5 newest entries, it should be encoded as a reference to that entry
        for i in 3...7 {
            let encoded = encoder.encode(headers: [.init(name: .init("\(i)")!, value: "")], forStream: 1)
            // The base is the insert count, ie 7
            let expectedIndexRelativeToBase = 7 - i
            #expect(
                encoded.fieldSection.lines.first == .indexed(.dynamicTable, index: expectedIndexRelativeToBase)
            )
        }
        // But if we try to encode a field referencing one of the older ones, the encoder will duplicate it first and then send a ref to the duplicate
        for i in 1...2 {
            let encoded = encoder.encode(headers: [.init(name: .init("\(i)")!, value: "")], forStream: 1)
            #expect(encoded.instructions == [.duplicateEntry(relativeIndex: 6)])
            // post base 0 because the new duplicate is the newest entry
            #expect(encoded.fieldSection.lines.first == .indexedWithPostBase(index: 0))
        }
    }

    /// We must not evict entries not yet acknowledged by the decoder.
    @Test
    func avoidEvictingUnacknowledgedEntries() throws {
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 165,
            dynamicTableInitialCapacity: 165,
            maxBlockedStreams: 100,
            targetEvictableFraction: 0.5
        )
        // We will add 5 entries, each has a length of 33
        // The total capacity is 165 which can only store 5 such entries
        for i in 1...5 {
            let encoded = encoder.encode(headers: [.init(name: .init("\(i)")!, value: "")], forStream: 1)
            #expect(encoded.instructions == [.insertWithLiteralName(name: "\(i)", value: "")])
            #expect(encoded.fieldSection.lines.first == .indexedWithPostBase(index: 0))
        }
        // Table is now full
        // Nothing was acked, so nothing is evictable. So we're forced to encode as a literal
        let encodedAsLiteral1 = encoder.encode(headers: [.init(name: .init("6")!, value: "")], forStream: 1)
        #expect(
            encodedAsLiteral1.fieldSection.lines.first
                == .literal(requireLiteralRepresentation: false, name: "6", value: "")
        )
        #expect(encodedAsLiteral1.instructions == .init())

        // Let's ack 2 sections
        try encoder.processInstruction(.sectionAcknowledgement(streamID: 1))
        try encoder.processInstruction(.sectionAcknowledgement(streamID: 1))

        // Now the oldest 2 entries are evictable. So we have room for 2 more
        for i in 7...8 {
            let encoded = encoder.encode(headers: [.init(name: .init("\(i)")!, value: "")], forStream: 1)
            #expect(encoded.instructions == [.insertWithLiteralName(name: "\(i)", value: "")])
            #expect(encoded.fieldSection.lines.first == .indexedWithPostBase(index: 0))
        }

        // Now again we are full, the next one should be encoded as a literal
        let encodedAsLiteral2 = encoder.encode(headers: [.init(name: .init("9")!, value: "")], forStream: 1)
        #expect(
            encodedAsLiteral2.fieldSection.lines.first
                == .literal(requireLiteralRepresentation: false, name: "9", value: "")
        )
        #expect(encodedAsLiteral2.instructions == .init())
    }

    @Test
    func initializeDynamicTableSendsInstruction() {
        _ = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 10,
            maxBlockedStreams: 100
        )
    }

    @Test
    func initializeDynamicTableWithNoInitialCapacity() {
        _ = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: 1000,
            dynamicTableInitialCapacity: 0,
            maxBlockedStreams: 100
        )
    }

    func assertEncodedAsLiteralWithNameReference(
        dynamicTableSize: Int,
        indexingStrategy: HTTPField.DynamicTableIndexingStrategy,
        expectRequireLiteralRepresentation: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        // Each test runs with its own encoder to avoid polluting state
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: dynamicTableSize,
            dynamicTableInitialCapacity: dynamicTableSize,
            maxBlockedStreams: 100
        )
        var header = HTTPField(name: .accept, value: "blabla")
        header.indexingStrategy = indexingStrategy
        let encoded = encoder.encode(headers: [header], forStream: 1)
        let expect = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
            lines: [
                FieldLine.literalWithNameReference(
                    requireLiteralRepresentation: expectRequireLiteralRepresentation,
                    table: .staticTable,
                    index: 29,
                    value: "blabla"
                )
            ]
        )
        #expect(encoded.fieldSection == expect, sourceLocation: sourceLocation)
        #expect(encoded.instructions == [], sourceLocation: sourceLocation)
    }

    func assertEncodedAsLiteralWithNameReferenceNoDynamic(
        indexingStrategy: HTTPField.DynamicTableIndexingStrategy,
        expectRequireLiteralRepresentation: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        // Each test runs with its own encoder to avoid polluting state
        let encoder = StaticQPACKEncoder()
        var header = HTTPField(name: .accept, value: "blabla")
        header.indexingStrategy = indexingStrategy
        let encoded = encoder.encode(headers: [header])
        let expect = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
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

    private func assertAddedToTableWithNameReference(
        dynamicTableSize: Int,
        indexingStrategy: HTTPField.DynamicTableIndexingStrategy,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        // Each test runs with its own encoder to avoid polluting state
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: dynamicTableSize,
            dynamicTableInitialCapacity: dynamicTableSize,
            maxBlockedStreams: 100
        )
        var header = HTTPField(name: .accept, value: "blabla")
        header.indexingStrategy = indexingStrategy
        let encoded = encoder.encode(headers: [header], forStream: 1)
        let expect = FieldSection(
            prefix: EncodedFieldSectionPrefix(encodedRequiredInsertCount: 2, deltaBase: 0, signBit: true),
            lines: [
                FieldLine.indexedWithPostBase(index: 0)
            ]
        )
        #expect(encoded.fieldSection == expect, sourceLocation: sourceLocation)
        #expect(
            encoded.instructions == [.insertWithNameReference(.staticTable, relativeIndex: 29, value: "blabla")],
            sourceLocation: sourceLocation
        )
    }

    @Test
    func indexingStrategyWithStaticTableMatch() {
        // These are the same because there is no dynamic table anyway
        for strategy in [HTTPField.DynamicTableIndexingStrategy.automatic, .prefer, .avoid] {
            self.assertEncodedAsLiteralWithNameReferenceNoDynamic(
                indexingStrategy: strategy,
                expectRequireLiteralRepresentation: false
            )
        }
        // But .disallow is different, because it also requires intermediaries to retain the literal
        self.assertEncodedAsLiteralWithNameReferenceNoDynamic(
            indexingStrategy: .disallow,
            expectRequireLiteralRepresentation: true
        )

        // In the following scenarios, there _is_ a dynamic table
        // When we disallow or avoid indexing, this behaves the same as when there is no table, because we're being told not to use the table
        self.assertEncodedAsLiteralWithNameReference(
            dynamicTableSize: 1000,
            indexingStrategy: .disallow,
            expectRequireLiteralRepresentation: true
        )
        self.assertEncodedAsLiteralWithNameReference(
            dynamicTableSize: 1000,
            indexingStrategy: .avoid,
            expectRequireLiteralRepresentation: false
        )
        // When we allow indexing, then this is the normal flow
        self.assertAddedToTableWithNameReference(
            dynamicTableSize: 1000,
            indexingStrategy: .automatic
        )
        self.assertAddedToTableWithNameReference(
            dynamicTableSize: 1000,
            indexingStrategy: .prefer
        )
    }

    @Test
    func maxBlockedStreams() throws {
        // Make the dynamic table really big, so that the only limitation is maxBlocked, not the size of the table
        let dynamicTableSize = 1_000_000_000
        var encoder = DynamicQPACKEncoder.makeAssertingInstructions(
            dynamicTableMaxCapacity: dynamicTableSize,
            dynamicTableInitialCapacity: dynamicTableSize,
            maxBlockedStreams: 2
        )
        let header1 = HTTPField(name: .userAgent, value: "h1")
        let header2 = HTTPField(name: .userAgent, value: "h2")

        // block stream 1
        // Total blocked count now 1 (stream 1)
        let result1 = encoder.encode(headers: [header1], forStream: 1)
        #expect(result1.fieldSection.lines == [.indexedWithPostBase(index: 0)])

        // block stream 2
        // Total blocked count now 2 (stream 1, 2)
        let result2 = encoder.encode(headers: [header1], forStream: 2)
        #expect(result2.fieldSection.lines == [.indexed(.dynamicTable, index: 0)])

        // Can't block stream 3, send literal
        // Total blocked count still 2 (stream 1, 2)
        let result3 = encoder.encode(headers: [header1], forStream: 3)
        #expect(
            result3.fieldSection.lines == [
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 95,
                    value: "h1"
                )
            ]
        )

        // We _are_ allowed to block stream 1 or 2 more, because they're already blocked, and it doesn't matter how blocked they are
        // Total blocked count still 2 (stream 1, 2)
        let result4 = encoder.encode(headers: [header2], forStream: 1)
        #expect(result4.fieldSection.lines == [.indexedWithPostBase(index: 0)])

        // Let's ack the first insert. This will unblock stream 2, but not 1, because 1 is double blocked
        // Total blocked count now 1 (stream 2)
        try encoder.processInstruction(.insertCountIncrement(increment: 1))

        // Can now block stream 4
        // Total blocked count now 2 (stream 2 and 4)
        let result5 = encoder.encode(headers: [header2], forStream: 4)
        #expect(result5.fieldSection.lines == [.indexed(.dynamicTable, index: 0)])

        // Now again we are not allowed to block on stream 3, because we already have 2 blocked (stream 2, 4)
        let result6 = encoder.encode(headers: [header2], forStream: 3)
        #expect(
            result6.fieldSection.lines == [
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 95,
                    value: "h2"
                )
            ]
        )

        // We _are_ allowed to send header 1 and reference that existing entry which is already acked. Because it's not blocking
        let result7 = encoder.encode(headers: [header1], forStream: 3)
        #expect(result7.fieldSection.lines == [.indexed(.dynamicTable, index: 1)])
    }
}

extension DynamicQPACKEncoder {
    /// Make an encoder and assert that the right instructions get sent.
    fileprivate static func makeAssertingInstructions(
        dynamicTableMaxCapacity: Int,
        dynamicTableInitialCapacity: Int,
        maxBlockedStreams: Int,
        targetEvictableFraction: Double = 0.1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Self {
        let (decoder, instructions) = Self.create(
            dynamicTableMaxCapacity: dynamicTableMaxCapacity,
            dynamicTableInitialCapacity: dynamicTableInitialCapacity,
            maxBlockedStreams: maxBlockedStreams,
            targetEvictableFraction: targetEvictableFraction
        )
        if dynamicTableInitialCapacity == 0 {
            #expect(instructions == nil, sourceLocation: sourceLocation)
        } else {
            #expect(
                instructions == .init(.setDynamicTableCapacity(dynamicTableInitialCapacity)),
                sourceLocation: sourceLocation
            )
        }
        return decoder
    }
}
