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

import NIOCore
@_spi(PackageInternal) @testable import QPACK
import Testing

struct FieldLineCodingTests {
    @Test
    func fieldSectionPrefixWithoutSign() throws {
        var buffer = ByteBuffer()
        let maxCapacity = 100
        let prefix = FieldSectionPrefix(requiredInsertCount: 40, base: 45)
        buffer.writeFieldSectionPrefix(prefix.encode(maxCapacity: maxCapacity))

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes == [
                // Required insert count, encoded
                5,  // (ReqInsertCount mod (2 * MaxEntries)) + 1 = 40 mod (2 * 3) + 1 = 40 mod 6 + 1 = 4 + 1 = 5
                // Sign bit (0), followed by the base delta (5)
                0b00000101,
            ]
        )

        let decoded = try buffer.readFieldSectionPrefix()
        // Encoding is done by using modulo 6 (6 being the maxCapacity * 2)
        // We can only decode if the decoder is within range of the correct totalInserts, i.e. 37...42
        for totalInserts in 37...42 {
            let fullyDecoded = decoded?.decode(totalInserts: totalInserts, maxCapacity: maxCapacity)
            #expect(fullyDecoded == prefix, "for total inserts \(totalInserts)")
        }
    }

    @Test
    func testFieldSectionPrefixWithSign() throws {
        var buffer = ByteBuffer()
        let maxCapacity = 100
        let prefix = FieldSectionPrefix(requiredInsertCount: 40, base: 35)
        buffer.writeFieldSectionPrefix(prefix.encode(maxCapacity: maxCapacity))

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes == [
                // Required insert count, encoded
                5,  // (ReqInsertCount mod (2 * MaxEntries)) + 1 = 40 mod (2 * 3) + 1 = 40 mod 6 + 1 = 4 + 1 = 5
                // Sign bit (1), followed by the base delta (4)
                0b10000100,
            ]
        )

        let decoded = try buffer.readFieldSectionPrefix()
        // Encoding is done by using modulo 6 (6 being the maxCapacity * 2)
        // We can only decode if the decoder is within range of the correct totalInserts, i.e. 37...42
        for totalInserts in 37...42 {
            let fullyDecoded = decoded?.decode(totalInserts: totalInserts, maxCapacity: maxCapacity)
            #expect(fullyDecoded == prefix, "for total inserts \(totalInserts)")
        }
    }

    @Test
    func testFieldSectionPrefixWithNoDelta() throws {
        var buffer = ByteBuffer()
        let maxCapacity = 100
        let prefix = FieldSectionPrefix(requiredInsertCount: 40, base: 40)
        buffer.writeFieldSectionPrefix(prefix.encode(maxCapacity: maxCapacity))

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes == [
                // Required insert count, encoded
                5,  // (ReqInsertCount mod (2 * MaxEntries)) + 1 = 40 mod (2 * 3) + 1 = 40 mod 6 + 1 = 4 + 1 = 5
                // Sign bit (0), followed by the base delta (0)
                0,
            ]
        )

        let decoded = try buffer.readFieldSectionPrefix()
        // Encoding is done by using modulo 6 (6 being the maxCapacity * 2)
        // We can only decode if the decoder is within range of the correct totalInserts, i.e. 37...42
        for totalInserts in 37...42 {
            let fullyDecoded = decoded?.decode(totalInserts: totalInserts, maxCapacity: maxCapacity)
            #expect(fullyDecoded == prefix, "for total inserts \(totalInserts)")
        }
    }

    @Test
    func testFieldSectionPrefixNegativeBase() throws {
        // An endpoint MUST treat a field block with a Sign bit of 1 as invalid if the value of Required Insert Count is less than or equal to the value of Delta Base.
        var buffer = ByteBuffer()
        let maxCapacity = 100
        let maxEntries = 3  // floor(MaxCapacity / 32)
        let requiredInsertCount = 5
        let encodedRequiredInsertCount = (requiredInsertCount % (2 * maxEntries)) + 1
        buffer.writeFieldSectionPrefix(
            .init(encodedRequiredInsertCount: encodedRequiredInsertCount, deltaBase: 6, signBit: true)
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes == [
                // Required insert count, encoded
                6,  // (ReqInsertCount mod (2 * MaxEntries)) + 1 = 5 mod (2 * 3) + 1 = 5 mod 6 + 1 = 5 + 1 = 6
                // Sign bit (1), followed by the base delta (6)
                0b10000110,
            ]
        )

        let decoded = try buffer.readFieldSectionPrefix()
        #expect(decoded != nil)
        let fullyDecoded = decoded?.decode(totalInserts: 5, maxCapacity: maxCapacity)
        #expect(fullyDecoded == nil)
    }

    @Test
    func testEncodeRequiredInsertCount() {
        func expectEncoding(original: Int, expect: Int, sourceLocation: SourceLocation = #_sourceLocation) {
            let prefix = FieldSectionPrefix(requiredInsertCount: original, base: 0)
            let encoded = prefix.encode(maxCapacity: maxCapacity)
            #expect(encoded.encodedRequiredInsertCount == expect, sourceLocation: sourceLocation)
        }

        let maxCapacity = 100
        // EncInsertCount = (ReqInsertCount mod (2 * MaxEntries)) + 1
        // maxEntries = maxCapacity / 32 = 100 / 32 = 3
        expectEncoding(original: 0, expect: 0)  // 0 is always 0
        expectEncoding(original: 1, expect: 2)
        expectEncoding(original: 2, expect: 3)
        expectEncoding(original: 3, expect: 4)
        expectEncoding(original: 4, expect: 5)
        expectEncoding(original: 5, expect: 6)
        expectEncoding(original: 6, expect: 1)
        expectEncoding(original: 7, expect: 2)
        expectEncoding(original: 8, expect: 3)
        expectEncoding(original: 9, expect: 4)
        expectEncoding(original: 10, expect: 5)
        expectEncoding(original: 11, expect: 6)
        expectEncoding(original: 12, expect: 1)
        expectEncoding(original: 13, expect: 2)
        expectEncoding(original: 14, expect: 3)
        expectEncoding(original: 15, expect: 4)
        expectEncoding(original: 16, expect: 5)
        expectEncoding(original: 17, expect: 6)
    }

    @Test
    func testDecodeRequiredInsertCountZero() {
        for maxCapacity in 0...100 {
            for totalInserts in 0...100 {
                let encoded = EncodedFieldSectionPrefix(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false)
                #expect(
                    encoded.decode(totalInserts: totalInserts, maxCapacity: maxCapacity)?.requiredInsertCount == 0
                )
            }
        }

    }

    @Test
    func testDecodeRequiredInsertCount() {
        let maxCapacity = 100

        func assertCannotDecode(
            encodedRequiredInsertCount: Int,
            totalInserts: Int,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let encoded = EncodedFieldSectionPrefix(
                encodedRequiredInsertCount: encodedRequiredInsertCount,
                deltaBase: 0,
                signBit: false
            )
            #expect(
                encoded.decode(totalInserts: totalInserts, maxCapacity: maxCapacity) == nil,
                sourceLocation: sourceLocation
            )
        }

        func assertCanDecode(
            encodedRequiredInsertCount: Int,
            totalInserts: Int,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let encoded = EncodedFieldSectionPrefix(
                encodedRequiredInsertCount: encodedRequiredInsertCount,
                deltaBase: 0,
                signBit: false
            )
            #expect(
                encoded.decode(totalInserts: totalInserts, maxCapacity: maxCapacity) != nil,
                sourceLocation: sourceLocation
            )
        }

        func assertCanDecode(
            encodedRequiredInsertCount: Int,
            totalInserts: Int,
            expectDecoded: Int,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let encoded = EncodedFieldSectionPrefix(
                encodedRequiredInsertCount: encodedRequiredInsertCount,
                deltaBase: 0,
                signBit: false
            )
            #expect(
                encoded.decode(totalInserts: totalInserts, maxCapacity: maxCapacity)?.requiredInsertCount
                    == expectDecoded,
                sourceLocation: sourceLocation
            )
        }

        // max entries is floor(maxCapacity / 32) = 3. Full range is x2 = 6
        // Therefore the encoded value cannot be more than 6
        // Total inserts doesn't matter
        for totalInserts in 0...50 {
            for i in 7...50 {
                assertCannotDecode(encodedRequiredInsertCount: i, totalInserts: totalInserts)
            }
        }
        // These ones should work because encoded value is less than 6
        // However, here the total inserts does matter because it determines how we decode
        // If total inserts is 3 (max capacity) or more, everything is valid...
        for totalInserts in 3...50 {
            for encoded in 0...6 {
                assertCanDecode(encodedRequiredInsertCount: encoded, totalInserts: totalInserts)
            }
        }
        // ... If the total inserts is less than 3, then certain encoded values are invalid because they could not
        // have been produced by a valid encoder. We'll write these test cases by hand
        assertCanDecode(encodedRequiredInsertCount: 0, totalInserts: 0, expectDecoded: 0)
        // 0 encodes to 0. 1 encodes to 2. 2 encodes to 3 etc. An encoded value of 1 is invalid for lower insert counts
        assertCannotDecode(encodedRequiredInsertCount: 1, totalInserts: 0)
        assertCanDecode(encodedRequiredInsertCount: 2, totalInserts: 0, expectDecoded: 1)
        assertCanDecode(encodedRequiredInsertCount: 3, totalInserts: 0, expectDecoded: 2)
        assertCanDecode(encodedRequiredInsertCount: 4, totalInserts: 0, expectDecoded: 3)
        assertCannotDecode(encodedRequiredInsertCount: 5, totalInserts: 0)  // too high because total is 0
        assertCannotDecode(encodedRequiredInsertCount: 6, totalInserts: 0)  // too high because total is 0

        assertCanDecode(encodedRequiredInsertCount: 0, totalInserts: 1, expectDecoded: 0)
        // 0 encodes to 0. 1 encodes to 2. 2 encodes to 3 etc. An encoded value of 1 is invalid for lower insert counts
        assertCannotDecode(encodedRequiredInsertCount: 1, totalInserts: 1)
        assertCanDecode(encodedRequiredInsertCount: 2, totalInserts: 1, expectDecoded: 1)
        assertCanDecode(encodedRequiredInsertCount: 3, totalInserts: 1, expectDecoded: 2)
        assertCanDecode(encodedRequiredInsertCount: 4, totalInserts: 1, expectDecoded: 3)
        assertCanDecode(encodedRequiredInsertCount: 5, totalInserts: 1, expectDecoded: 4)
        assertCannotDecode(encodedRequiredInsertCount: 6, totalInserts: 1)  // too high because total is 1

        assertCanDecode(encodedRequiredInsertCount: 0, totalInserts: 2, expectDecoded: 0)
        // 0 encodes to 0. 1 encodes to 2. 2 encodes to 3 etc. An encoded value of 1 is invalid for lower insert counts
        assertCannotDecode(encodedRequiredInsertCount: 1, totalInserts: 2)
        assertCanDecode(encodedRequiredInsertCount: 2, totalInserts: 2, expectDecoded: 1)
        assertCanDecode(encodedRequiredInsertCount: 3, totalInserts: 2, expectDecoded: 2)
        assertCanDecode(encodedRequiredInsertCount: 4, totalInserts: 2, expectDecoded: 3)
        assertCanDecode(encodedRequiredInsertCount: 5, totalInserts: 2, expectDecoded: 4)
        assertCanDecode(encodedRequiredInsertCount: 6, totalInserts: 2, expectDecoded: 5)
    }

    @Test
    func testEncodeFieldSectionPrefixRoundtrips() {
        for maxCapacity in 200...400 {
            for requiredInsertCount in 1...20 {
                // The encoder and decoder need to have similar insert counts for this to work
                for totalInserts in (requiredInsertCount - 5)...(requiredInsertCount + 5) {
                    for base in 0...5 {
                        let prefix = FieldSectionPrefix(requiredInsertCount: requiredInsertCount, base: base)
                        let encoded = prefix.encode(maxCapacity: maxCapacity)
                        let decoded = encoded.decode(totalInserts: totalInserts, maxCapacity: maxCapacity)
                        #expect(decoded == prefix)
                    }
                }
            }
        }
    }

    @Test
    func testIndex() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(.indexed(.staticTable, index: 6), preferHuffmanEncoding: false)

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes == [0b11000110]  // 1, then T (1), then the index (6)
        )

        let decoded = try buffer.readFieldLine()
        #expect(decoded == .indexed(.staticTable, index: 6))
    }

    @Test
    func testIndexWithPostBase() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(.indexedWithPostBase(index: 6), preferHuffmanEncoding: false)

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes == [0b00010110]  // 0001, then index (6)
        )

        let decoded = try buffer.readFieldLine()
        #expect(decoded == .indexedWithPostBase(index: 6))
    }

    @Test
    func testLiteralWithNameReference() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(
            .literalWithNameReference(
                requireLiteralRepresentation: false,
                table: .dynamicTable,
                index: 9,
                value: "hello"
            ),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                == [0b01001001]  // 01, then N (0), then T (0), then index (9)
                // Then length of value (5)
                + [5]
                // Then value
                + "hello".utf8
        )

        let decoded = try buffer.readFieldLine()
        #expect(
            decoded
                == .literalWithNameReference(
                    requireLiteralRepresentation: false,
                    table: .dynamicTable,
                    index: 9,
                    value: "hello"
                )
        )
    }

    @Test
    func testLiteralWithNameReferencePostBase() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(
            .literalWithNameReferenceWithPostBase(requireLiteralRepresentation: false, index: 3, value: "hello"),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                == [0b00000011]  // 0000, then N (0), then index (3)
                // Then length of value (5)
                + [5]
                // Then value
                + "hello".utf8
        )

        let decoded = try buffer.readFieldLine()
        #expect(
            decoded
                == .literalWithNameReferenceWithPostBase(requireLiteralRepresentation: false, index: 3, value: "hello")
        )
    }

    @Test
    func testLiteral() throws {
        var buffer = ByteBuffer()
        buffer.writeFieldLine(
            .literal(requireLiteralRepresentation: true, name: "Name", value: "Value"),
            preferHuffmanEncoding: false
        )

        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes)
        #expect(
            bytes
                // 001, then N (1), then length of name (4)
                == [0b00110100]
                + "Name".utf8
                // The length of the value, i.e. 5
                + [0b00000101]
                + "Value".utf8
        )

        let decoded = try buffer.readFieldLine()
        #expect(decoded == .literal(requireLiteralRepresentation: true, name: "Name", value: "Value"))
    }
}
