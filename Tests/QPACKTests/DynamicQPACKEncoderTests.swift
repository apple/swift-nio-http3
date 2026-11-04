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
struct DynamicQPACKEncoderTests {
    /// ``StaticQPACKEncoderTests/headers``, none of which may use the dynamic table.
    static let staticOnlyHeaders = StaticQPACKEncoderTests.headers.map { header in
        var header = header
        if header.indexingStrategy != .disallow {
            header.indexingStrategy = .avoid
        }
        return header
    }

    /// Two encoders in the same state encode the same fields, one into a ``FieldSection`` and one into an
    /// `OutputRawSpan`. Over enough sections the Base and the Required Insert Count outgrow a byte, and the prefix
    /// sometimes takes a different length than expected. Every fourth section references no dynamic table entry, so
    /// its Delta Base is the whole Base.
    @available(anyAppleOS 27, *)
    @Test(arguments: [true, false])
    func encoderWritesItsFieldSection(preferHuffmanEncoding: Bool) throws {
        var reference = DynamicQPACKEncoder.create(
            peersDecoderTableMaxCapacity: 4096,
            dynamicTableMaxCapacity: 4096,
            dynamicTableInitialCapacity: 4096,
            maxBlockedStreams: 100,
            targetEvictableFraction: 0.5
        ).0
        // A copy: the encoder holds no references.
        var encoder = reference
        var sectionsWithLongDeltaBase = 0

        for round in 0..<400 {
            let streamID = QUICStreamID(rawValue: UInt64(round) * 4)
            let headers: [HTTPField]
            if round % 4 == 3 {
                headers = Self.staticOnlyHeaders
            } else {
                // A field with a new name, so that the section inserts into the table. A new value alone would only
                // reference the name inserted in an earlier round.
                headers =
                    StaticQPACKEncoderTests.headers + [HTTPField(name: .init("x-round-\(round)")!, value: "\(round)")]
            }
            let expected = reference.encode(headers: headers, forStream: streamID)
            if expected.fieldSection.prefix.encodedRequiredInsertCount == 0
                && QPACKEncodedLength.prefixedInteger(expected.fieldSection.prefix.deltaBase, prefix: 7) > 1
            {
                sectionsWithLongDeltaBase += 1
            }

            let (buffer, instructions) = encoder.encodeIntoExactBound(
                headers: headers,
                forStream: streamID,
                preferHuffmanEncoding: preferHuffmanEncoding
            )

            // Comparing bytes, not decoded field sections, checks the Huffman coding too.
            #expect(
                buffer == ByteBuffer(fieldSection: expected.fieldSection, preferHuffmanEncoding: preferHuffmanEncoding),
                "round \(round)"
            )
            #expect(instructions == expected.instructions, "round \(round)")

            // Acknowledge the section, so its entries can be evicted to make room for the next ones.
            if expected.fieldSection.prefix.encodedRequiredInsertCount != 0 {
                try reference.processInstruction(.sectionAcknowledgement(streamID: streamID))
                try encoder.processInstruction(.sectionAcknowledgement(streamID: streamID))
            }
        }
        #expect(sectionsWithLongDeltaBase > 0)
    }

    /// RFC 9204 § 4.5.1.1: The Required Insert Count is encoded with the MaxEntries of the decoder, 2048 here, not
    /// the 128 of the encoder's smaller table. With the encoder's, the encoded Required Insert Count wraps around at
    /// 256 inserts, and the decoder rejects it.
    @available(anyAppleOS 27, *)
    @Test func requiredInsertCountIsEncodedWithTheDecodersMaxEntries() throws {
        var (encoder, setCapacity) = DynamicQPACKEncoder.create(
            peersDecoderTableMaxCapacity: 65536,
            dynamicTableMaxCapacity: 4096,
            dynamicTableInitialCapacity: 4096,
            maxBlockedStreams: 100,
            targetEvictableFraction: 0.5
        )
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 65536)
        _ = try decoder.processInstruction(try #require(setCapacity))

        for round in 0..<300 {
            let streamID = QUICStreamID(rawValue: UInt64(round) * 4)
            let headers = [HTTPField(name: .init("x-round-\(round)")!, value: "\(round)")]
            var (buffer, instructions) = encoder.encodeIntoExactBound(
                headers: headers,
                forStream: streamID,
                preferHuffmanEncoding: true
            )
            for instruction in instructions {
                _ = try decoder.processInstruction(instruction)
            }

            let fieldSection = try #require(try buffer.readFieldSection(), "round \(round)")
            let prefix = try #require(decoder.decodeFieldSectionPrefix(fieldSection.prefix), "round \(round)")
            let decoded = try decoder.decodeFieldSection(
                prefix: prefix,
                lines: fieldSection.lines,
                streamID: streamID
            ).unwrap()
            let (fields, acknowledgement) = try #require(decoded, "round \(round)")
            #expect(fields.map(\.value) == headers.map(\.value), "round \(round)")

            // Acknowledge the section, so its entries can be evicted to make room for the next ones.
            if let acknowledgement {
                try encoder.processInstruction(acknowledgement)
            }
        }
    }

    @available(anyAppleOS 27, *)
    @Test func writesNothingButThePrefixForNoFields() {
        var encoder = DynamicQPACKEncoder.create(
            peersDecoderTableMaxCapacity: 4096,
            dynamicTableMaxCapacity: 4096,
            dynamicTableInitialCapacity: 4096,
            maxBlockedStreams: 100,
            targetEvictableFraction: 0.5
        ).0
        let (buffer, instructions) = encoder.encodeIntoExactBound(
            headers: [],
            forStream: QUICStreamID(rawValue: 0),
            preferHuffmanEncoding: true
        )
        // Required Insert Count 0, then Base 0
        #expect(Array(buffer.readableBytesView) == [0, 0])
        #expect(instructions.isEmpty)
    }
}

@available(anyAppleOS 27, *)
extension DynamicQPACKEncoder {
    /// Encodes `headers` into a span of exactly ``maxEncodedLength(of:)`` bytes, so that a bound that's too small
    /// traps. A `ByteBuffer` rounds its capacity up, which would hide it.
    fileprivate mutating func encodeIntoExactBound(
        headers: [HTTPField],
        forStream streamID: QUICStreamID,
        preferHuffmanEncoding: Bool
    ) -> (ByteBuffer, [QPACKEncoderInstruction]) {
        var bytes = [UInt8](repeating: 0, count: self.maxEncodedLength(of: headers))
        let (length, instructions) = bytes.withUnsafeMutableBytes { buffer in
            var output = OutputRawSpan(buffer: buffer, initializedCount: 0)
            let instructions = self.encode(
                headers: headers,
                forStream: streamID,
                into: &output,
                preferHuffmanEncoding: preferHuffmanEncoding
            )
            return (output.finalize(for: buffer), instructions)
        }
        return (ByteBuffer(bytes: bytes.prefix(length)), instructions)
    }
}
