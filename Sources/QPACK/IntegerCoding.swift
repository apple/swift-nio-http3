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

public import struct NIOCore.ByteBuffer

private let valueMask: UInt8 = 127
private let continuationMask: UInt8 = 128

extension ByteBuffer {
    /// Encodes an integer value into a provided memory location, using the format defined in RFC 9204 § 4.1.1.
    ///
    /// - Parameters:
    ///   - value: The integer value to encode.
    ///   - prefix: The number of bits available for use in the first byte at `buffer`.
    ///   - prefixBits: Existing bits to place in that first byte of `buffer` before encoding `value`.
    /// - Returns: Returns the number of bytes used to encode the integer.
    @discardableResult
    @inlinable
    mutating func writeQPACKPrefixedInteger<Integer: FixedWidthInteger>(
        _ value: Integer,
        prefix: Int,
        prefixBits: UInt8 = 0
    ) -> Int {
        assert(prefix <= 8)
        assert(prefix >= 1)
        precondition(value >= 0, "Negative integers cannot be encoded in QPACK.")

        let start = self.writerIndex

        // The prefix is always hard-coded, and must fit within 8, so unchecked math here is definitely safe.
        let k = (1 &<< prefix) &- 1
        var initialByte = prefixBits

        if value < k {
            // it fits already!
            initialByte |= UInt8(truncatingIfNeeded: value)
            self.writeInteger(initialByte)
            return 1
        }

        // if it won't fit in this byte altogether, fill in all the remaining bits and move
        // to the next byte.
        initialByte |= UInt8(truncatingIfNeeded: k)
        self.writeInteger(initialByte)

        // deduct the initial [prefix] bits from the value, then encode it seven bits at a time into
        // the remaining bytes.
        // We can safely use unchecked subtraction here: we know that `k` is zero or greater, and that `value` is
        // either the same value or greater. As a result, this can be unchecked: it's always safe.
        var n = value &- Integer(k)
        while n >= 128 {
            let nextByte = (1 << 7) | UInt8(truncatingIfNeeded: n & 0x7f)
            self.writeInteger(nextByte)
            n >>= 7
        }

        self.writeInteger(UInt8(truncatingIfNeeded: n))
        return self.writerIndex &- start
    }

    /// Reads an integer encoded using the format defined in RFC 9204 § 4.1.1.
    /// Moves the reader index forward by the number of bytes read.
    /// If no integer can be read, returns nil and leaves the index as it was.
    /// - Precondition: The prefix MUST be between 1 and 8 inclusive.
    /// - Throws: IntegerReadingError if the result doesn't fit in the requested type.
    mutating func readQPACKPrefixedInteger<Integer: FixedWidthInteger & Sendable>(
        as: Integer.Type = Integer.self,
        withPrefix prefix: Int
    ) throws(IntegerReadingError) -> Integer? {
        guard let result = try getQPACKPrefixedInteger(as: Integer.self, at: self.readerIndex, withPrefix: prefix)
        else {
            return nil
        }
        self.moveReaderIndex(forwardBy: result.bytesRead)
        return result.value
    }

    /// Gets an integer encoded using the format defined in RFC 9204 § 4.1.1.
    /// Does not affect the reader index.
    /// - Precondition: The prefix MUST be between 1 and 8 inclusive.
    /// - Throws: IntegerReadingError if the result doesn't fit in the requested type.
    func getQPACKPrefixedInteger<Integer: FixedWidthInteger>(
        as: Integer.Type = Integer.self,
        at startIndex: Int,
        withPrefix prefix: Int
    ) throws(IntegerReadingError) -> Decoded<Integer>? {
        guard (1...8).contains(prefix) else {
            preconditionFailure("Prefixed integer must have a prefix between 1 and 8")
        }
        if startIndex >= self.writerIndex {
            return nil
        }

        // See RFC 7541 § 5.1 for details of the encoding/decoding.

        var index = startIndex
        // The shifting and arithmetic operate on 'Int' and prefix is 1...8, so these unchecked operations are
        // fine and the result must fit in a UInt8.
        let prefixMask = UInt8(truncatingIfNeeded: (1 &<< prefix) &- 1)
        // Safe to bang because we already did a startIndex >= self.writerIndex check
        let prefixBits = self.getInteger(at: index, as: UInt8.self)! & prefixMask

        if prefixBits != prefixMask {
            // The prefix bits aren't all '1', so they represent the whole value, we're done.
            return Decoded(value: Integer(prefixBits), bytesRead: 1)
        }

        var accumulator = Integer(prefixMask)
        index += 1

        // for the remaining bytes, as long as the top bit is set, consume the low seven bits.
        var shift = 0
        var byte: UInt8 = 0

        repeat {
            if index == self.writerIndex {
                return nil
            }

            // Safe to bang because we already did a startIndex == self.writerIndex check
            byte = self.getInteger(at: index, as: UInt8.self)!

            let value = Integer(byte & valueMask)

            // The shift cannot overflow: the value of 'shift' is strictly less than 'Int.bitWidth'.
            let (multiplicationResult, multiplicationOverflowed) = value.multipliedReportingOverflow(by: 1 &<< shift)
            if multiplicationOverflowed {
                throw IntegerReadingError.unrepresentable
            }

            let (additionResult, additionOverflowed) = accumulator.addingReportingOverflow(multiplicationResult)
            if additionOverflowed {
                throw IntegerReadingError.unrepresentable
            }

            accumulator = additionResult

            // Unchecked is fine, there's no chance of it overflowing given the possible values of 'Int.bitWidth'.
            shift &+= 7
            if shift >= Int.bitWidth {
                throw IntegerReadingError.unrepresentable
            }

            index += 1
        } while byte & continuationMask == continuationMask

        return Decoded(value: accumulator, bytesRead: index - startIndex)
    }
}
