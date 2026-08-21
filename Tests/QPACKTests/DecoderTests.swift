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
import NIOQUICHelpers
@_spi(PackageInternal) @testable import QPACK
import Testing

struct DecoderTests {
    @Test
    func testDecodeLiteral() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 0)

        let prefix = FieldSectionPrefix(requiredInsertCount: 0, base: 0)
        let line = FieldLine.literal(requireLiteralRepresentation: false, name: "hello", value: "World")
        let fields: [HTTPField]? = try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        tester.assertNoMoreInstructions()

        #expect(fields == [HTTPField(name: .init("Hello")!, value: "World")])
    }

    @Test
    func testDecodeIndexedStatic() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 0)

        let prefix = FieldSectionPrefix(requiredInsertCount: 0, base: 0)
        let line = FieldLine.indexed(.staticTable, index: 46)
        let fields: [HTTPField]? = try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        tester.assertNoMoreInstructions()

        #expect(fields == [HTTPField(name: .init("content-type")!, value: "application/json")])
    }

    @Test
    func testDecodeIndexedStaticPseudo() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 0)

        let prefix = FieldSectionPrefix(requiredInsertCount: 0, base: 0)
        let line = FieldLine.indexed(.staticTable, index: 17)
        let fields: [HTTPField]? = try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        tester.assertNoMoreInstructions()

        #expect(fields == [HTTPField(name: .init(parsed: ":method")!, value: "GET")])
    }

    @Test
    func testDecodeLiteralValueIndexedNameStatic() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 0)

        let prefix = FieldSectionPrefix(requiredInsertCount: 0, base: 0)
        let line = FieldLine.literalWithNameReference(
            requireLiteralRepresentation: true,
            table: .staticTable,
            index: 46,
            value: "image/png"
        )
        let fields: [HTTPField]? = try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        tester.assertNoMoreInstructions()

        #expect(fields == [HTTPField(name: .contentType, value: "image/png")])
    }

    @Test
    func testDecodeIndexedStaticInvalidRef() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 100)
        let result = decoder.decodeFieldSection(
            prefix: .init(requiredInsertCount: 0, base: 0),
            lines: [.indexed(.staticTable, index: 10000)],
            streamID: 0
        )
        #expect(throws: QPACKDecoderError.invalidReference) { try result.unwrap() }
    }

    @Test
    func testDecodeIndexedStaticNameReferenceInvalid() {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 100)
        let result = decoder.decodeFieldSection(
            prefix: .init(requiredInsertCount: 0, base: 0),
            lines: [
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .staticTable,
                    index: 10000,
                    value: "hi"
                )
            ],
            streamID: 0
        )
        #expect(throws: QPACKDecoderError.invalidReference) { try result.unwrap() }
    }

    @Test
    func testDecodeIndexedDynamic() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 1000)
        try tester.processInstruction(.setDynamicTableCapacity(1000))

        try tester.processInstruction(.insertWithLiteralName(name: "hello1", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        try tester.processInstruction(.insertWithLiteralName(name: "hello2", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        let prefix = FieldSectionPrefix(requiredInsertCount: 1, base: 1)
        // a relative index of 0 refers to the entry with absolute index equal to Base - 1
        // Base is 1. So it refers to absolute index 0
        // Indexing starts from 0, i.e the 1st entry. Which is hello1
        let line = FieldLine.indexed(.dynamicTable, index: 0)
        let fields: [HTTPField]? = try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        #expect(tester.popInstruction() == .sectionAcknowledgement(streamID: 1))
        tester.assertNoMoreInstructions()
        #expect(fields == [HTTPField(name: .init("Hello1")!, value: "World")])
    }

    /// Ask the decoder to decode a field section with a required insert count of 1, when the table is empty. Then add an entry to unblock the decoder.
    @Test
    func testDecodeIndexedDynamicBlocked() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 1000)
        try tester.processInstruction(.setDynamicTableCapacity(1000))

        let prefix = FieldSectionPrefix(requiredInsertCount: 1, base: 1)
        // a relative index of 0 refers to the entry with absolute index equal to Base - 1
        // Base is 1. So it refers to absolute index 0, ie the first entry
        // This entry does not exist yet!
        let line = FieldLine.indexed(.dynamicTable, index: 0)

        guard case .missingInsertCount = tester.decodeFieldSection(prefix, lines: [line]) else {
            Issue.record("Unexpected decode result")
            return
        }

        // Unblock by inserting a field
        try tester.processInstruction(.insertWithLiteralName(name: "hello", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        let decodeResult = tester.decodeFieldSection(prefix, lines: [line])
        guard case .success(let fields) = decodeResult else {
            Issue.record("Unexpected decode result")
            return
        }
        #expect(tester.popInstruction() == .sectionAcknowledgement(streamID: 1))
        tester.assertNoMoreInstructions()
        #expect(fields == [HTTPField(name: .init("Hello")!, value: "World")])
    }

    /// Ask the decoder to decode a field section with a required insert count of 5, when the table is empty. Then add entries until unblocked.
    @Test
    func testDecodeIndexedDynamicMultipleBlocked() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 1000)
        try tester.processInstruction(.setDynamicTableCapacity(1000))

        // Start off with one entry
        try tester.processInstruction(.insertWithLiteralName(name: "hello1", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        // a relative index of 0 refers to the entry with absolute index equal to Base - 1
        let line = FieldLine.indexed(.dynamicTable, index: 0)

        let prefix1 = FieldSectionPrefix(requiredInsertCount: 1, base: 1)  // will refer to 1st entry
        let prefix2 = FieldSectionPrefix(requiredInsertCount: 2, base: 2)  // will refer to 2nd entry
        let prefix5 = FieldSectionPrefix(requiredInsertCount: 5, base: 5)  // will refer to 5th entry
        // Send to decoder out of order, it shouldn't matter
        let firstDecodeResult2 = tester.decodeFieldSection(prefix2, lines: [line])
        let firstDecodeResult5 = tester.decodeFieldSection(prefix5, lines: [line])
        let decodeResult1 = tester.decodeFieldSection(prefix1, lines: [line])
        // The 5 and 2 should get queued, 1 is processable
        guard case .success(let result1) = decodeResult1 else {
            Issue.record("Unexpected decode result1")
            return
        }
        guard case .missingInsertCount = firstDecodeResult2 else {
            Issue.record("Unexpected decode result2")
            return
        }
        guard case .missingInsertCount = firstDecodeResult5 else {
            Issue.record("Unexpected decode result5")
            return
        }

        // One message should have been processed already
        #expect(tester.popInstruction() == .sectionAcknowledgement(streamID: 1))

        // Unblock the 2nd by adding one field
        try tester.processInstruction(.insertWithLiteralName(name: "hello2", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        // 2nd message can be processed now
        let decodeResult2 = tester.decodeFieldSection(prefix2, lines: [line])
        #expect(tester.popInstruction() == .sectionAcknowledgement(streamID: 1))

        // Unblock the 3rd and last message by adding 3 more fields
        for i in 3...5 {
            try tester.processInstruction(.insertWithLiteralName(name: "hello\(i)", value: "World"))
            #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))
        }

        // Now last can be processed
        let decodeResult5 = tester.decodeFieldSection(prefix5, lines: [line])
        #expect(tester.popInstruction() == .sectionAcknowledgement(streamID: 1))

        // Check the 3 results

        let fields1: [HTTPField] = result1
        let fields2: [HTTPField]? = try decodeResult2.unwrap()
        let fields5: [HTTPField]? = try decodeResult5.unwrap()

        #expect(fields1 == [HTTPField(name: .init("Hello1")!, value: "World")])
        #expect(fields2 == [HTTPField(name: .init("Hello2")!, value: "World")])
        #expect(fields5 == [HTTPField(name: .init("Hello5")!, value: "World")])

        tester.assertNoMoreInstructions()
    }

    @Test
    func testDecodeIndexedDynamicDuplicated() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 1000)
        try tester.processInstruction(.setDynamicTableCapacity(1000))

        try tester.processInstruction(.insertWithLiteralName(name: "hello", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        try tester.processInstruction(.duplicateEntry(relativeIndex: 0))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        let prefix = FieldSectionPrefix(requiredInsertCount: 1, base: 1)
        let line = FieldLine.indexed(.dynamicTable, index: 0)
        let fields: [HTTPField]? = try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        #expect(tester.popInstruction() == .sectionAcknowledgement(streamID: 1))
        tester.assertNoMoreInstructions()

        #expect(fields == [HTTPField(name: .init("Hello")!, value: "World")])
    }

    @Test
    func testDecodeLiteralValueIndexedNameDynamic() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 1000)
        try tester.processInstruction(.setDynamicTableCapacity(100))

        try tester.processInstruction(.insertWithLiteralName(name: "hello", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        let prefix = FieldSectionPrefix(requiredInsertCount: 1, base: 1)
        let line = FieldLine.literalWithNameReference(
            requireLiteralRepresentation: true,
            table: .dynamicTable,
            index: 0,
            value: "NewValue"
        )
        let fields: [HTTPField]? = try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        #expect(tester.popInstruction() == .sectionAcknowledgement(streamID: 1))
        tester.assertNoMoreInstructions()

        #expect(fields == [HTTPField(name: .init("Hello")!, value: "NewValue")])
    }

    @Test
    func testDecodeLiteralValueIndexedNameDynamicInvalidReference() {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        let result = decoder.decodeFieldSection(
            prefix: .init(requiredInsertCount: 0, base: 0),
            lines: [
                .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .dynamicTable,
                    index: 0,  // this entry doesn't exist (in fact, none do)
                    value: "hi"
                )
            ],
            streamID: 0
        )
        #expect(throws: QPACKDecoderError.invalidReference) { try result.unwrap() }
    }

    @Test
    func testDecodeLiteralValueIndexedNameDynamicInvalidReferencePostBase() {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        let result = decoder.decodeFieldSection(
            prefix: .init(requiredInsertCount: 0, base: 0),
            lines: [
                .literalWithNameReferenceWithPostBase(
                    requireLiteralRepresentation: false,
                    index: 0,  // this entry doesn't exist (in fact, none do)
                    value: "hi"
                )
            ],
            streamID: 0
        )
        #expect(throws: QPACKDecoderError.invalidReference) { try result.unwrap() }
    }

    @Test
    func testDecodeIndexedDynamicPostBase() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 1000)
        try tester.processInstruction(.setDynamicTableCapacity(1000))

        try tester.processInstruction(.insertWithLiteralName(name: "hello1", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        try tester.processInstruction(.insertWithLiteralName(name: "hello2", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        try tester.processInstruction(.insertWithLiteralName(name: "hello3", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        let prefix = FieldSectionPrefix(requiredInsertCount: 3, base: 1)
        // Post-Base indices are used in field line representations for entries with absolute indices greater than or
        // equal to Base, starting at 0 for the entry with absolute index equal to Base and increasing in the same
        // direction as the absolute index.
        // So 1 refers to absolute index of base + 1. Base is 0 so that makes 1
        let line = FieldLine.indexedWithPostBase(index: 0)
        let fields: [HTTPField]? = try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        #expect(tester.popInstruction() == .sectionAcknowledgement(streamID: 1))
        tester.assertNoMoreInstructions()

        #expect(fields == [HTTPField(name: .init("Hello2")!, value: "World")])
    }

    @Test
    func testDecodeLiteralValueIndexedNameDynamicPostBase() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 1000)
        try tester.processInstruction(.setDynamicTableCapacity(1000))
        for absoluteIndex in 0...10 {
            try tester.processInstruction(.insertWithLiteralName(name: "hello\(absoluteIndex)", value: "World"))
            #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))
        }

        let prefix = FieldSectionPrefix(requiredInsertCount: 3, base: 1)
        let line = FieldLine.literalWithNameReferenceWithPostBase(
            requireLiteralRepresentation: true,
            index: 6,  // absolute index 7 (base + 6)
            value: "NewValue"
        )
        let fields: [HTTPField]? = try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        #expect(tester.popInstruction() == .sectionAcknowledgement(streamID: 1))
        tester.assertNoMoreInstructions()

        #expect(fields == [HTTPField(name: .init("Hello7")!, value: "NewValue")])
    }

    @Test
    func testDecodeIndexedWithPostBaseInvalidRef() {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        let result = decoder.decodeFieldSection(
            prefix: .init(requiredInsertCount: 0, base: 0),
            lines: [.indexedWithPostBase(index: 0)],  // entry doesn't exist
            streamID: 0
        )
        #expect(throws: QPACKDecoderError.invalidReference) { try result.unwrap() }
    }

    @Test
    func testDecodeInvalidReference() throws {
        let tester = QPACKDecoderTester(dynamicTableMaxCapacity: 1000)
        try tester.processInstruction(.setDynamicTableCapacity(1000))

        try tester.processInstruction(.insertWithLiteralName(name: "hello", value: "World"))
        #expect(tester.popInstruction() == .insertCountIncrement(increment: 1))

        let prefix = FieldSectionPrefix(requiredInsertCount: 1, base: 0)
        let line = FieldLine.indexed(.dynamicTable, index: 0)  // invalid because table only has 1 entry
        #expect(throws: QPACKDecoderError.invalidReference) {
            try tester.decodeFieldSection(prefix, lines: [line]).unwrap()
        }
        tester.assertNoMoreInstructions()
    }

    // MARK: Test processing instructions

    @Test
    func testSetCapacity() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(500)
    }

    @Test
    func testSetCapacityInvalid() {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        #expect(throws: DynamicHeaderTableError.capacityTooHigh) {
            try decoder.processInstruction(.setDynamicTableCapacity(2000))
        }
    }

    @Test
    func testInsertLiteral() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(100)
        try decoder.assertInsertEntry(name: "test", value: "hello")
    }

    @Test
    func testInsertInvalidLiteral() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(100)
        // Upper case field names are forbidden
        #expect(throws: QPACKDecoderError.invalidHeaderName) {
            try decoder.processInstruction(.insertWithLiteralName(name: "Test", value: "1"))
        }
    }

    @Test
    func testInsertLiteralNoSpace() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(1)
        #expect(throws: HeaderTableError.insufficientStorage) {
            try decoder.processInstruction(.insertWithLiteralName(name: "test", value: "1"))
        }
    }

    @Test
    func testInsertWithStaticNameRef() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(1000)

        let instruction = QPACKEncoderInstruction.insertWithNameReference(.staticTable, relativeIndex: 5, value: "hi")
        let returnInstructions = try decoder.processInstruction(instruction)
        #expect(returnInstructions == .insertCountIncrement(increment: 1))
    }

    @Test
    func testInsertWithInvalidStaticNameRef() {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        // Relative index 2000 doesn't exist
        let instruction = QPACKEncoderInstruction.insertWithNameReference(
            .staticTable,
            relativeIndex: 2000,
            value: "hi"
        )
        #expect(throws: QPACKDecoderError.invalidReference) {
            try decoder.processInstruction(instruction)
        }
    }

    @Test
    func testInsertWithDynamicNameRef() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(100)
        try decoder.assertInsertEntry(name: "test", value: "hello")

        let instruction = QPACKEncoderInstruction.insertWithNameReference(.dynamicTable, relativeIndex: 0, value: "hi")
        let returnInstructions = try decoder.processInstruction(instruction)
        #expect(returnInstructions == .insertCountIncrement(increment: 1))
    }

    @Test
    func testInsertWithInvalidDynamicNameRef() {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        // Relative index 0 is invalid because there's nothing in the table
        let instruction = QPACKEncoderInstruction.insertWithNameReference(.dynamicTable, relativeIndex: 0, value: "hi")
        #expect(throws: QPACKDecoderError.invalidReference) {
            try decoder.processInstruction(instruction)
        }
    }

    @Test
    func testDuplicateEntry() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(1000)
        try decoder.assertInsertEntry(name: "test", value: "hello")
        // Duplicate the last entry
        let returnInstructions = try decoder.processInstruction(.duplicateEntry(relativeIndex: 0))
        #expect(returnInstructions == .insertCountIncrement(increment: 1))
    }

    @Test
    func testDuplicateInvalidEntry() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(1000)
        // Duplicate the last entry. But it doesn't exist because we didn't insert anything yet
        #expect(throws: QPACKDecoderError.invalidReference) {
            try decoder.processInstruction(.duplicateEntry(relativeIndex: 0))
        }
    }

    @Test
    func testReferenceEvictingEntry() throws {
        // A new entry can reference an entry in the dynamic table that will be evicted when adding this new entry into the dynamic table.
        // Implementations are cautioned to avoid deleting the referenced name or value if the referenced entry is evicted from the
        // dynamic table prior to inserting the new entry.

        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(35)  // fits only one entry
        try decoder.assertInsertEntry(name: "a", value: "b")

        let returnInstructions = try decoder.processInstruction(
            .insertWithNameReference(.dynamicTable, relativeIndex: 0, value: "c")
        )

        #expect(returnInstructions == .insertCountIncrement(increment: 1))

        // The only entry in the table should now be name: a, value: c
        let result = decoder.decodeFieldSection(
            prefix: .init(requiredInsertCount: 2, base: 1),
            lines: [.indexedWithPostBase(index: 0)],
            streamID: 1
        )
        let unwrapped = try? result.unwrap()
        #expect(unwrapped?.0 == [.init(name: .init("a")!, value: "c")])
    }

    @Test
    func testCancelStreamWhenMaxCapacityZero() throws {
        let decoder = QPACKDecoder(dynamicTableMaxCapacity: 0)  // Max and current capacity both 0.
        let returnInstructions = decoder.cancelStream(streamID: 1)
        // Cancelling a stream when there is no dynamic table does not require telling the other side
        #expect(returnInstructions == nil)
    }

    @Test
    func testCancelStreamWhenCurrentCapacityZero() throws {
        let decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)  // This is the max. The current capacity is still 0.
        let returnInstructions = decoder.cancelStream(streamID: 1)
        // Cancelling a stream when the current capacity is 0 DOES still require telling the other side because the maximum is non-0
        #expect(returnInstructions == .streamCancellation(streamID: 1))
    }

    @Test
    func testCancelStreamWhenHasCapacity() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1000)
        try decoder.assertSetDynamicTableCapacity(1000)
        let returnInstructions = decoder.cancelStream(streamID: 1)
        // An instruction is emitted to tell the other side that we cancelled the stream, so it can drop any references.
        #expect(returnInstructions == .streamCancellation(streamID: 1))
    }
}

extension QPACKDecoder {
    fileprivate mutating func assertSetDynamicTableCapacity(_ capacity: Int) throws {
        let returnInstructions = try self.processInstruction(.setDynamicTableCapacity(capacity))
        #expect(returnInstructions == nil)
    }

    fileprivate mutating func assertInsertEntry(name: String, value: String) throws {
        let instruction = QPACKEncoderInstruction.insertWithLiteralName(name: name, value: value)
        let returnInstructions = try self.processInstruction(instruction)
        #expect(returnInstructions == .insertCountIncrement(increment: 1))
    }
}

/// A helper for testing the decoder.
/// Wraps the decoder functions and returns only the actual results, not the instructions.
/// Instructions go into a recorder, in order, which you can pop and assert on.
private class QPACKDecoderTester {
    /// The decoder being tested.
    private var decoder: QPACKDecoder
    /// The instructions that we have seen.
    private var recordedInstructions: [QPACKDecoderInstruction] = []

    init(dynamicTableMaxCapacity: Int) {
        self.decoder = QPACKDecoder(dynamicTableMaxCapacity: dynamicTableMaxCapacity)
    }

    func processInstruction(_ instruction: QPACKEncoderInstruction) throws {
        if let result = try self.decoder.processInstruction(instruction) {
            self.recordedInstructions.append(result)
        }
    }

    func assertNoMoreInstructions(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(self.recordedInstructions == [], sourceLocation: sourceLocation)
    }

    func popInstruction() -> QPACKDecoderInstruction? {
        if self.recordedInstructions.isEmpty {
            return nil
        }
        return self.recordedInstructions.removeFirst()
    }

    func decodeFieldSection(
        _ prefix: FieldSectionPrefix,
        lines: [FieldLine],
        streamID: QUICStreamID = 1
    ) -> QPACKDecodeResult {
        let result = self.decoder.decodeFieldSection(prefix: prefix, lines: lines, streamID: streamID)
        switch result {
        case .missingInsertCount:
            return .missingInsertCount
        case .success(let fields, let instruction):
            if let instruction {
                self.recordedInstructions.append(instruction)
            }
            return .success(fields)
        case .error(let error):
            return .error(error)
        }
    }
}

extension QPACKDecodeResult {
    fileprivate func unwrap() throws -> [HTTPField]? {
        switch self {
        case .missingInsertCount:
            return nil
        case .success(let result):
            return result
        case .error(let error):
            throw error
        }
    }
}
