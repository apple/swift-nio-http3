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

@_spi(PackageInternal) @testable import HTTP3

/// Tests for ``QPACKCoder``.
struct QPACKCoderTests {

    // MARK: Encode

    @Test func encodeUsesTheStaticTable() {
        let coder = QPACKCoder()
        let encoded = coder.encodeHeaders([
            .init(name: .init(parsed: ":method")!, value: "GET"),
            .init(name: .init("x-custom")!, value: "value"),
        ])

        // The Required Insert Count is always zero: nothing references the dynamic table.
        #expect(encoded.fieldSection.prefix == .staticOnly)
        #expect(
            encoded.fieldSection.lines == [
                .indexed(.staticTable, index: 17),
                .literal(requireLiteralRepresentation: false, name: "x-custom", value: "value"),
            ]
        )
    }

    // MARK: Decode

    @Test func decodeReturnsFieldsSynchronously() throws {
        let coder = QPACKCoder()
        let fields: [HTTPField] = [
            .init(name: .init(parsed: ":method")!, value: "GET"),
            .init(name: .init("x-custom")!, value: "value"),
        ]

        #expect(try coder.decodeHeaders(coder.encodeHeaders(fields)) == fields)
    }

    @Test func decodeOfADynamicTableReferenceIsAConnectionError() {
        let coder = QPACKCoder()
        let headers = HTTP3PartialFrame.Headers(
            fieldSection: .init(prefix: .staticOnly, lines: [.indexed(.dynamicTable, index: 0)])
        )

        #expect {
            try coder.decodeHeaders(headers)
        } throws: { error in
            guard case .connectionError(let error) = error as? QPACKCoder.DecodeError else { return false }
            return error.h3ErrorCode == .qpackDecompressionFailed
        }
    }

    @Test func decodeOfANonZeroRequiredInsertCountIsAConnectionError() {
        let coder = QPACKCoder()
        let prefix = EncodedFieldSectionPrefix(encodedRequiredInsertCount: 2, deltaBase: 0, signBit: false)
        let headers = HTTP3PartialFrame.Headers(
            fieldSection: .init(prefix: prefix, lines: [.indexed(.staticTable, index: 17)])
        )

        #expect {
            try coder.decodeHeaders(headers)
        } throws: { error in
            guard case .connectionError(let error) = error as? QPACKCoder.DecodeError else { return false }
            return error.h3ErrorCode == .qpackDecompressionFailed
        }
    }

    @Test func decodeOfAMalformedHeaderNameIsAStreamError() {
        let coder = QPACKCoder()
        let headers = HTTP3PartialFrame.Headers(
            fieldSection: .init(
                prefix: .staticOnly,
                // An upper case field name is malformed in HTTP/3.
                lines: [.literal(requireLiteralRepresentation: false, name: "Upper", value: "case")]
            )
        )

        #expect {
            try coder.decodeHeaders(headers)
        } throws: { error in
            guard case .streamError(let error) = error as? QPACKCoder.DecodeError else { return false }
            return error.h3ErrorCode == .messageError
        }
    }

    // MARK: Peer instructions

    /// A peer which respects our zero `SETTINGS_QPACK_MAX_TABLE_CAPACITY` may still set the capacity to zero.
    @Test func settingTheDynamicTableCapacityToZeroIsAccepted() {
        #expect(QPACKCoder().receivedEncoderInstruction(.setDynamicTableCapacity(0)) == nil)
    }

    @Test(arguments: [
        QPACKEncoderInstruction.setDynamicTableCapacity(1024),
        QPACKEncoderInstruction.insertWithLiteralName(name: "cookie", value: "test"),
        QPACKEncoderInstruction.insertWithNameReference(.staticTable, relativeIndex: 0, value: "test"),
        QPACKEncoderInstruction.duplicateEntry(relativeIndex: 0),
    ])
    func anyOtherEncoderInstructionIsAConnectionError(instruction: QPACKEncoderInstruction) {
        let error = QPACKCoder().receivedEncoderInstruction(instruction)
        #expect(error?.h3ErrorCode == .qpackEncoderStreamError)
    }

    /// Our encoder never references the dynamic table, so the peer's decoder has nothing to tell us.
    @Test(arguments: [
        QPACKDecoderInstruction.sectionAcknowledgement(streamID: 0),
        QPACKDecoderInstruction.streamCancellation(streamID: 0),
        QPACKDecoderInstruction.insertCountIncrement(increment: 1),
    ])
    func anyDecoderInstructionIsAConnectionError(instruction: QPACKDecoderInstruction) {
        let error = QPACKCoder().receivedDecoderInstruction(instruction)
        #expect(error?.h3ErrorCode == .qpackDecoderStreamError)
    }
}
