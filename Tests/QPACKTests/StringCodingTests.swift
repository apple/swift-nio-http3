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
import Testing

@_spi(PackageInternal) @testable import QPACK

struct StringCodingTests {
    private var scratchBuffer = ByteBufferAllocator().buffer(capacity: 11)

    private mutating func encodeStringToArray(_ value: String, preferHuffmanEncoding: Bool, prefix: Int) -> [UInt8] {
        self.scratchBuffer.clear()
        let len = self.scratchBuffer.writeQPACKEncodedString(
            value,
            preferHuffmanEncoding: preferHuffmanEncoding,
            prefix: prefix
        )
        return Array(self.scratchBuffer.viewBytes(at: 0, length: len)!)
    }

    private mutating func decodeString(from array: [UInt8], withPrefix prefix: Int) throws -> String? {
        self.scratchBuffer.clear()
        self.scratchBuffer.writeBytes(array)
        return try self.scratchBuffer.readQPACKEncodedString(withPrefix: prefix)
    }

    @Test(arguments: 2...8)
    mutating func testStringDecodingEmptyInput(prefix: Int) throws {
        // RFC 9204 § 4.1.2: The prefix size, N, can have a value between 2 and 8, inclusive
        let result = try self.decodeString(from: [], withPrefix: prefix)
        #expect(result == nil)
    }

    // MARK: Encoding with Huffman

    @Test
    mutating func testStringEncodingWithHuffmanNoPrefix() {
        #expect(
            self.encodeStringToArray("www.example.com", preferHuffmanEncoding: true, prefix: 8)
                // The first byte is used from the start because prefix is 8
                // The first bit means this is huffman encoded
                // The remaining 7 bits represent the length of the encoded string, which is 12
                // Then the next 12 bytes represent the string itself
                == [0b10001100, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]
        )
    }

    @Test
    mutating func testStringEncodingWithHuffmanWithPrefix() {
        #expect(
            self.encodeStringToArray("www.example.com", preferHuffmanEncoding: true, prefix: 5)
                // The first byte is used from the 3rd bit because prefix is 5
                // The first bit after the prefix, ie the 4th bit, is 1 which means this is huffman encoded
                // The remaining 4 bits represent the length of the encoded string, which is 12
                // Then the next 12 bytes represent the string itself
                == [0b00011100, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]
        )
    }

    // MARK: Encoding with Huffman preferred but not used

    @Test
    mutating func testStringEncodingNoHuffmanDespitePreferredNoPrefixBecauseShort() {
        #expect(
            // A single character can't possibly be compressed
            self.encodeStringToArray("a", preferHuffmanEncoding: true, prefix: 8)
                // The first byte is used from the start because prefix is 8
                // The first bit 0 means this is not huffman encoded
                // The remaining 7 bits represent the length of the encoded string, which is 1
                // Then the next byte represents the string itself
                == [0b00000001] + "a".utf8
        )
    }

    @Test
    mutating func testStringEncodingNoHuffmanDespitePreferredNoPrefixBecauseNotASCII() {
        #expect(
            // Non ASCII characters don't compress well
            self.encodeStringToArray("éééééééééé", preferHuffmanEncoding: true, prefix: 8)
                // The first byte is used from the start because prefix is 8
                // The first bit 0 means this is not huffman encoded
                // The remaining 7 bits represent the length of the encoded string, which is 20
                // Then the next byte represents the string itself
                == [0b00010100] + "éééééééééé".utf8
        )
    }

    // MARK: Decoding with Huffman

    @Test
    mutating func testStringDecodingWithHuffmanNoPrefix() throws {
        let result = try self.decodeString(
            // The first byte is used from the start because prefix is 8
            // The first bit means this is huffman encoded
            // The remaining 7 bits represent the length of the encoded string, which is 12
            // Then the next 12 bytes represent the string itself
            from: [0b10001100, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff],
            withPrefix: 8
        )
        #expect(result == "www.example.com")
    }

    @Test
    mutating func testStringDecodingWithHuffmanWithPrefix() throws {
        let result = try self.decodeString(
            // The first byte is used from the 3rd bit because prefix is 5
            // The first bit after the prefix, ie the 4th bit, is 1 which means this is huffman encoded
            // The remaining 4 bits represent the length of the encoded string, which is 12
            // Then the next 12 bytes represent the string itself
            from: [0b10111100, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff],
            withPrefix: 5
        )
        #expect(result == "www.example.com")
    }

    // MARK: Encoding without Huffman

    @Test
    mutating func testStringEncodingNoPrefix() {
        #expect(
            self.encodeStringToArray("test", preferHuffmanEncoding: false, prefix: 8)
                // The first byte is used from the start because prefix is 8
                // The first bit means this is NOT huffman encoded
                // The remaining 7 bits represent the length of the encoded string, which is 4
                // Then the next 4 bytes represent the string itself
                == [0b00000100] + "test".utf8
        )
    }

    @Test
    mutating func testStringEncodingWithPrefix() {
        #expect(
            self.encodeStringToArray("test", preferHuffmanEncoding: false, prefix: 5)
                // prefix is 5 so we only use the last 5 bits of the first byte
                // The first bit after the prefix, ie the 4th bit, is 0 which means this is NOT huffman encoded
                // The remaining 4 bits represent the length of the encoded string, which is 4 (0100)
                // Then the next 4 bytes represent the string itself
                == [0b00000100] + "test".utf8
        )
    }

    @Test
    mutating func testStringEncodingWhenLengthFillsThePrefix() {
        #expect(
            self.encodeStringToArray("testing", preferHuffmanEncoding: false, prefix: 4)
                // prefix is 4 so we only use the last 4 bits of the first byte
                // The first bit after the prefix, ie the 5th bit, is 0 which means this is NOT huffman encoded
                // The length (7) cannot fit in the prefix, because that can only happen if it's less than less than 2^N-1 ie 7
                // 7 is not less than 7
                // Therefore all the bytes are set to 1, and then 7 - 2^N-1 is encoded in the next byte (ie 0)
                // Then the next 7 bytes represent the string itself
                == [0b00000111, 0] + "testing".utf8
        )
    }

    @Test
    mutating func testStringEncodingWhenLengthLong() {
        #expect(
            self.encodeStringToArray("testingtesting", preferHuffmanEncoding: false, prefix: 4)
                // prefix is 4 so we only use the last 4 bits of the first byte
                // The first bit after the prefix, ie the 5th bit, is 0 which means this is NOT huffman encoded
                // The length (14) cannot fit in the prefix, because that can only happen if it's less than less than 2^N-1 ie 7
                // 14 is not less than 7
                // Therefore all the bytes are set to 1, and then 14 - 2^N-1 (ie 7) is encoded in the next byte (ie 00000111)
                // Then the next 14 bytes represent the string itself
                == [0b00000111, 0b00000111] + "testingtesting".utf8
        )
    }

    // MARK: Decoding without Huffman

    @Test
    mutating func testStringDecodingNoPrefix() throws {
        let result = try self.decodeString(
            // The first byte is used from the start because prefix is 8
            // The first bit means this is NOT huffman encoded
            // The remaining 7 bits represent the length of the encoded string, which is 4
            // Then the next 4 bytes represent the string itself
            from: [0b00000100] + "test".utf8,
            withPrefix: 8
        )
        #expect(result == "test")
    }

    @Test
    mutating func testStringDecodingWithPrefix() throws {
        let result = try self.decodeString(
            // prefix is 5 so we only use the last 5 bits of the first byte
            // The first bit after the prefix, ie the 4th bit, is 0 which means this is NOT huffman encoded
            // The remaining 4 bits represent the length of the encoded string, which is 4 (0100)
            // Then the next 4 bytes represent the string itself
            from: [0b11100100] + "test".utf8,
            withPrefix: 5
        )
        #expect(result == "test")
    }

    @Test
    mutating func testStringDecodingWhenLengthFillsThePrefix() throws {
        let result = try self.decodeString(
            // prefix is 4 so we only use the last 4 bits of the first byte
            // The first bit after the prefix, ie the 5th bit, is 0 which means this is NOT huffman encoded
            // The length (7) cannot fit in the prefix, because that can only happen if it's less than less than 2^N-1 ie 7
            // 7 is not less than 7
            // Therefore all the bytes are set to 1, and then 7 - 2^N-1 is encoded in the next byte (ie 0)
            // Then the next 7 bytes represent the string itself
            from: [0b00000111, 0] + "testing".utf8,
            withPrefix: 4
        )
        #expect(result == "testing")
    }

    @Test
    mutating func testStringDecodingWhenLengthLong() throws {
        let result = try self.decodeString(
            // prefix is 4 so we only use the last 4 bits of the first byte
            // The first bit after the prefix, ie the 5th bit, is 0 which means this is NOT huffman encoded
            // The length (14) cannot fit in the prefix, because that can only happen if it's less than less than 2^N-1 ie 7
            // 14 is not less than 7
            // Therefore all the bytes are set to 1, and then 14 - 2^N-1 (ie 7) is encoded in the next byte (ie 00000111)
            // Then the next 14 bytes represent the string itself
            from: [0b00000111, 0b00000111] + "testingtesting".utf8,
            withPrefix: 4
        )
        #expect(result == "testingtesting")
    }

    // MARK: Misc

    @Test
    mutating func testDecodeMalformed() throws {
        // This is malformed because the first byte suggests a length of 2, but there is only 1 further byte
        var buffer = ByteBuffer(bytes: [2, 0])
        let result = try buffer.readQPACKEncodedString(withPrefix: 8)
        #expect(result == nil)
        // Index should not be moved
        #expect(buffer.readableBytes == 2)
    }

    @Test
    mutating func testDecodeMalformedMidBuffer() throws {
        // This is malformed because the first byte suggests a length of 2, but there is only 1 further byte.
        // This is testing for a specific bug in the implementation of getQPACKEncodedString.
        // The buffer has 3 readable bytes, so there appear to be enough bytes.
        // But there aren't, because we're reading starting from index 1
        let buffer = ByteBuffer(bytes: [0, 2, 0])
        let result = try buffer.getQPACKEncodedString(at: 1, withPrefix: 8)
        #expect(result == nil)
        // Index should not be moved
        #expect(buffer.readableBytes == 3)
    }

    @Test(arguments: (1...50).flatMap { x in (2...8).map { y in (x, y) } })
    mutating func testRoundtrips(testStringLength: Int, testPrefix: Int) throws {
        let testString = String(repeating: "x", count: testStringLength)
        for preferHuffmanEncoding in [true, false] {
            let encoded = self.encodeStringToArray(
                testString,
                preferHuffmanEncoding: preferHuffmanEncoding,
                prefix: testPrefix
            )
            let decoded = try self.decodeString(from: encoded, withPrefix: testPrefix)
            #expect(
                decoded == testString,
                "Failed to roundtrip string of length \(testStringLength) with prefix: \(testPrefix). Huffman: \(preferHuffmanEncoding)"
            )
        }
    }

    @Test
    mutating func testLengthOverflow() {
        // The readQPACKEncodedString function reads the length as an int. UInt.max > Int.max so this should throw.
        let length: UInt = .max
        var buffer = ByteBuffer()
        buffer.writeQPACKPrefixedInteger(length, prefix: 8)
        buffer.writeBytes([1, 2, 3, 4])

        #expect(throws: IntegerReadingError.unrepresentable) {
            try buffer.readQPACKEncodedString(withPrefix: 8)
        }
    }
}
