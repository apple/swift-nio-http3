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
import Testing

@_spi(PackageInternal) @testable import QPACK

/// Tests that the dynamic encoder writes the field sections it describes into an `OutputRawSpan`, within the room it
/// asks for.
struct DynamicQPACKCoderTests {
    /// Two encoders in the same state encode the same fields, one into a ``FieldSection`` and one into an
    /// `OutputRawSpan`. Over enough sections the Base and the Required Insert Count outgrow a byte, and the prefix
    /// usually takes less room than was reserved for it.
    @available(anyAppleOS 27, *)
    @Test(arguments: [true, false])
    func encoderWritesItsFieldSection(preferHuffmanEncoding: Bool) throws {
        func makeEncoder() -> DynamicQPACKEncoder {
            DynamicQPACKEncoder.create(
                dynamicTableMaxCapacity: 4096,
                dynamicTableInitialCapacity: 4096,
                maxBlockedStreams: 100,
                targetEvictableFraction: 0.5
            ).0
        }
        var reference = makeEncoder()
        var encoder = makeEncoder()

        for round in 0..<300 {
            let streamID = QUICStreamID(rawValue: UInt64(round) * 4)
            // A field with a new name every round, so that every section inserts into the table. A new value alone
            // would only reference the name inserted in an earlier round.
            let headers =
                StaticQPACKEncoderTests.headers + [HTTPField(name: .init("x-round-\(round)")!, value: "\(round)")]
            let expected = reference.encode(headers: headers, forStream: streamID)

            var instructions = [QPACKEncoderInstruction]()
            let bound = encoder.maxEncodedLength(of: headers)
            var buffer = ByteBuffer(initialCapacity: bound) { output in
                instructions = encoder.encode(
                    headers: headers,
                    forStream: streamID,
                    into: &output,
                    preferHuffmanEncoding: preferHuffmanEncoding
                )
            }
            #expect(buffer.readableBytes <= bound, "round \(round)")

            let decoded = try buffer.readFieldSection()
            #expect(buffer.readableBytes == 0, "round \(round)")
            #expect(decoded == expected.fieldSection, "round \(round)")
            #expect(instructions == expected.instructions, "round \(round)")

            // Acknowledge the section, so its entries can be evicted to make room for the next ones.
            if expected.fieldSection.prefix.encodedRequiredInsertCount != 0 {
                try reference.processInstruction(.sectionAcknowledgement(streamID: streamID))
                try encoder.processInstruction(.sectionAcknowledgement(streamID: streamID))
            }
        }
    }

    @available(anyAppleOS 27, *)
    @Test func appendedPrefixMovesTheLinesAfterItBack() {
        let prefix = EncodedFieldSectionPrefix(encodedRequiredInsertCount: 3, deltaBase: 0, signBit: true)
        let buffer = ByteBuffer(initialCapacity: 8) { output in
            output.append(0xAA)
            // Four bytes reserved, of which the prefix needs two.
            output.appendFieldSection(maxPrefixLength: 4) { lines in
                lines.append(0xBB)
                lines.append(0xCC)
                return prefix
            }
        }
        #expect(Array(buffer.readableBytesView) == [0xAA, 3, 0b10000000, 0xBB, 0xCC])
    }
}
