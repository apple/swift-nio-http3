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

    /// Field sections written by the dynamic encoder decode to the fields they were encoded from. Over enough sections
    /// the Base and the Required Insert Count outgrow a byte, and the prefix sometimes takes a different length than
    /// expected. Every fourth section references no dynamic table entry, so its Delta Base is the whole Base.
    @available(anyAppleOS 27, *)
    @Test(arguments: [true, false])
    func encoderWritesItsFieldSection(preferHuffmanEncoding: Bool) throws {
        var (encoder, setCapacity) = DynamicQPACKEncoder.create(
            peersDecoderTableMaxCapacity: 4096,
            dynamicTableMaxCapacity: 4096,
            dynamicTableInitialCapacity: 4096,
            maxBlockedStreams: 100,
            targetEvictableFraction: 0.5
        )
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 4096)
        _ = try decoder.processInstruction(try #require(setCapacity))
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

            let (buffer, instructions) = encodeWithExactRoom(encoder.maxEncodedLength(of: headers)) {
                encoder.encode(
                    headers: headers,
                    forStream: streamID,
                    into: &$0,
                    preferHuffmanEncoding: preferHuffmanEncoding
                )
            }
            let fieldSection = FieldSection(readingAll: buffer)
            // Reading undoes the Huffman coding, so check it by writing the lines back.
            #expect(
                buffer == ByteBuffer(fieldSection: fieldSection, preferHuffmanEncoding: preferHuffmanEncoding),
                "round \(round)"
            )
            if fieldSection.prefix.encodedRequiredInsertCount == 0
                && QPACKEncodedLength.prefixedInteger(fieldSection.prefix.deltaBase, prefix: 7) > 1
            {
                sectionsWithLongDeltaBase += 1
            }

            for instruction in instructions {
                _ = try decoder.processInstruction(instruction)
            }
            let prefix = try #require(decoder.decodeFieldSectionPrefix(fieldSection.prefix), "round \(round)")
            let decoded = try decoder.decodeFieldSection(
                prefix: prefix,
                lines: fieldSection.lines,
                streamID: streamID
            ).unwrap()
            let (fields, acknowledgement) = try #require(decoded, "round \(round)")
            // Only the canonical names and the values go over the wire.
            #expect(
                fields.map { [$0.name.canonicalName, $0.value] } == headers.map { [$0.name.canonicalName, $0.value] },
                "round \(round)"
            )

            // Acknowledge the section, so its entries can be evicted to make room for the next ones.
            if let acknowledgement {
                try encoder.processInstruction(acknowledgement)
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
            var (buffer, instructions) = encodeWithExactRoom(encoder.maxEncodedLength(of: headers)) {
                encoder.encode(headers: headers, forStream: streamID, into: &$0, preferHuffmanEncoding: true)
            }
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
        let (buffer, instructions) = encodeWithExactRoom(encoder.maxEncodedLength(of: [])) {
            encoder.encode(headers: [], forStream: QUICStreamID(rawValue: 0), into: &$0, preferHuffmanEncoding: true)
        }
        // Required Insert Count 0, then Base 0
        #expect(Array(buffer.readableBytesView) == [0, 0])
        #expect(instructions.isEmpty)
    }
}
