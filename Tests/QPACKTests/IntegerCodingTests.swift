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

struct IntegerCodingTests {
    private var scratchBuffer = ByteBufferAllocator().buffer(capacity: 11)

    // MARK: - Array-based helpers

    private mutating func encodeIntegerToArray(_ value: UInt64, prefix: Int) -> [UInt8] {
        var data = [UInt8]()
        self.scratchBuffer.clear()
        let len = self.scratchBuffer.writeQPACKPrefixedInteger(value, prefix: prefix)
        data.append(contentsOf: self.scratchBuffer.viewBytes(at: 0, length: len)!)
        return data
    }

    private mutating func decodeInteger(from array: [UInt8], prefix: Int) throws -> Int? {
        self.scratchBuffer.clear()
        self.scratchBuffer.writeBytes(array)
        return try self.scratchBuffer.readQPACKPrefixedInteger(withPrefix: prefix)
    }

    // MARK: - Tests

    @Test
    mutating func testIntegerEncoding() throws {
        // values from the standard: http://httpwg.org/specs/rfc7541.html#integer.representation.examples
        var data = self.encodeIntegerToArray(10, prefix: 5)  // 0000 1010
        #expect(data == [0b00001010])

        data = self.encodeIntegerToArray(1337, prefix: 5)  // 0000 0101 0011 1001
        // prefix bits = 31 = 0001 1111, 1337 - 31 = 1306 = 0101 0001 1010 -> x0001010 x0011010
        #expect(data == [31, 154, 10])  // 00011111 , 10011010 , 00001010

        // prefix 8 == use the whole first octet
        data = self.encodeIntegerToArray(42, prefix: 8)  // 0010 1010
        #expect(data == [42])

        data = self.encodeIntegerToArray(256, prefix: 8)  // 0001 0000 0000 -> 1111 1111 + 0000 0001
        #expect(data == [255, 1])

        // very large value, few bits set, 8-bit prefix
        data = self.encodeIntegerToArray(17 << 57, prefix: 8)  // 00010001 << 57 or 2449958197289549824

        // calculations:
        //  subtract prefix:
        //      2449958197289549824 - 255 = 2449958197289549569 or 0010 0001 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 0000 0001
        //  seven bits at a time, grouping from least significant bit:
        //      0100001 1111111 1111111 1111111 1111111 1111111 1111111 1111110 0000001
        //  swap these around:
        //      0000001 1111110 1111111 1111111 1111111 1111111 1111111 1111111 0100001
        //  set the top bit of all but last part to get our remaining output bytes:
        //      10000001 11111110 11111111 11111111 11111111 11111111 11111111 11111111 00100001
        #expect(data == [255, 129, 254, 255, 255, 255, 255, 255, 255, 33])

        // same value, 1-bit prefix:
        data = self.encodeIntegerToArray(17 << 57, prefix: 1)

        // calculations:
        //  subtract prefix:
        //      2449958197289549824 - 1 = 2449958197289549823 or 0010 0001 (1111 x14)
        //  seven bits at a time, grouping from least significant bit:
        //      0100001 1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111111
        //  swap these around:
        //      1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111111 0100001
        //  set the top bit of all but last part to get our remaining output bytes:
        //      11111111 11111111 11111111 11111111 11111111 11111111 11111111 11111111 00100001
        #expect(data == [1, 255, 255, 255, 255, 255, 255, 255, 255, 33])

        // encoding max 64-bit unsigned integer, 1-bit prefix
        data = self.encodeIntegerToArray(UInt64.max, prefix: 1)

        // calculations:
        //  subtract prefix:
        //      18446744073709551615 - 1 = 18446744073709551614 or (1111 x15) 1110
        //  seven bits at a time, grouping from least significant bit:
        //      0000001 1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111110
        //  swap these around:
        //      1111110 1111111 1111111 1111111 1111111 1111111 1111111 1111111 1111111 0000001
        //  set the top bit of all but last part to get our remaining output bytes:
        //      11111110 11111111 11111111 11111111 11111111 11111111 11111111 11111111 11111111 00000001
        #expect(data == [1, 254, 255, 255, 255, 255, 255, 255, 255, 255, 1])

        // something carefully crafted to produce maximum number of output bytes with minimum number of
        // nonzero bits:
        data = self.encodeIntegerToArray(9_223_372_036_854_775_809, prefix: 1)

        // calculations:
        //  subtract prefix:
        //      9223372036854775809 - 1 = 9223372036854775808 or 1000 (0000 x15)
        //  seven bits at a time, grouping from least significant bit:
        //      (000000)1 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000
        //  swap these around:
        //      0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000001
        //  set the top bit of all but the last part to get our remaining output bytes:
        //      10000000 10000000 10000000 10000000 10000000 10000000 10000000 10000000 10000000 00000001
        #expect(data == [1, 128, 128, 128, 128, 128, 128, 128, 128, 128, 1])

        // something similar, which uses an 8-bit prefix and still produces lots of zero bits:
        // for those interested: this is the previous value + 254; thus only the first byte should differ
        data = self.encodeIntegerToArray(9_223_372_036_854_776_063, prefix: 8)

        // calculations:
        //  subtract prefix:
        //      9223372036854776063 - 255 = 9223372036854775808 or 1000 (0000 x15)
        //  seven bits at a time, grouping from least significant bit:
        //      (000000)1 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000
        //  swap these around:
        //      0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000000 0000001
        //  set the top bit of all but the last part to get our remaining output bytes:
        //      10000000 10000000 10000000 10000000 10000000 10000000 10000000 10000000 10000000 00000001
        #expect(data == [255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 1])
    }

    @Test
    mutating func testIntegerDecoding() throws {
        // any bits above the prefix amount shouldn't affect the outcome.
        try #expect(self.decodeInteger(from: [0b00001010], prefix: 5) == 10)
        try #expect(self.decodeInteger(from: [0b11101010], prefix: 5) == 10)

        try #expect(self.decodeInteger(from: [0b00011111, 154, 10], prefix: 5) == 1337)
        try #expect(self.decodeInteger(from: [0b11111111, 154, 10], prefix: 5) == 1337)

        try #expect(self.decodeInteger(from: [0b00101010], prefix: 8) == 42)

        // Now some larger numbers:
        try #expect(
            self.decodeInteger(from: [255, 129, 254, 255, 255, 255, 255, 255, 255, 33], prefix: 8)
                == 2_449_958_197_289_549_824
        )
        try #expect(
            self.decodeInteger(from: [1, 255, 255, 255, 255, 255, 255, 255, 255, 33], prefix: 1)
                == 2_449_958_197_289_549_824
        )
        try #expect(
            self.decodeInteger(from: [1, 254, 255, 255, 255, 255, 255, 255, 255, 127, 1], prefix: 1) == Int.max
        )

        // lots of zeroes: each 128 yields zero
        try #expect(
            self.decodeInteger(from: [1, 128, 128, 128, 128, 128, 128, 128, 128, 127, 1], prefix: 1)
                == 9_151_314_442_816_847_873
        )

        // almost the same bytes, but a different prefix:
        try #expect(
            self.decodeInteger(from: [255, 128, 128, 128, 128, 128, 128, 128, 128, 127, 1], prefix: 8)
                == 9_151_314_442_816_848_127
        )

        // now a silly version which should never have been encoded in so many bytes
        try #expect(self.decodeInteger(from: [255, 129, 128, 128, 128, 128, 128, 128, 128, 0], prefix: 8) == 256)
    }

    @Test(arguments: 1...8)
    mutating func testIntegerDecodingMultiplicationDoesNotOverflow(prefix: Int) {
        // Zeros with continuation bits (e.g. 128) to increase the shift value (to 9 * 7 = 63), and then multiply by 127.
        #expect(throws: IntegerReadingError.unrepresentable) {
            try self.decodeInteger(from: [255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 127], prefix: prefix)
        }
    }

    @Test(arguments: 1...8)
    mutating func testIntegerDecodingAdditionDoesNotOverflow(prefix: Int) {
        // Zeros with continuation bits (e.g. 128) to increase the shift value (to 9 * 7 = 63), and then multiply by 127.
        #expect(throws: IntegerReadingError.unrepresentable) {
            try self.decodeInteger(from: [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 127], prefix: prefix)
        }
    }

    @Test(arguments: 1...8)
    mutating func testIntegerDecodingShiftDoesNotOverflow(prefix: Int) {
        // With enough iterations we expect the shift to become greater >= 64.
        #expect(throws: IntegerReadingError.unrepresentable) {
            try self.decodeInteger(from: [255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128], prefix: prefix)
        }
    }

    @Test(arguments: 1...8)
    mutating func testIntegerDecodingEmptyInput(prefix: Int) throws {
        try #expect(self.decodeInteger(from: [], prefix: prefix) == nil)
    }

    @Test(arguments: 1...8)
    mutating func testIntegerDecodingNotEnoughBytes(prefix: Int) throws {
        try #expect(self.decodeInteger(from: [255, 128], prefix: prefix) == nil)
    }
}
