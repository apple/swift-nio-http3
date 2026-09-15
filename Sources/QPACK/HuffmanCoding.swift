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

import struct NIOCore.ByteBuffer

/// Adds QPACK-conformant Huffman encoding to `ByteBuffer`.
extension ByteBuffer {
    fileprivate struct _EncoderState {
        var offset = 0
        var remainingBits = 8
    }

    /// Returns the number of *bits* required to encode a given string.
    @available(anyAppleOS 26.0, *)
    fileprivate static func huffmanEncodedBitLength(of bytes: some Collection<UInt8>) -> Int {
        let numberOfBits = bytes.reduce(0) { $0 + HuffmanEncoderTable[$1].nbits }
        // round up to nearest multiple of 8 for EOS prefix
        return (numberOfBits + 7) & ~7
    }

    /// Returns the number of bytes required to encode a given string.
    @available(anyAppleOS 26.0, *)
    static func huffmanEncodedByteLength(of bytes: some Collection<UInt8>) -> Int {
        self.huffmanEncodedBitLength(of: bytes) / 8
    }

    /// Encodes the given string to the buffer, using QPACK Huffman encoding.
    ///
    /// - Parameters:
    ///   - stringBytes: The data to encode.
    ///   - encodedByteLength: The encoded length of `stringBytes`, as returned
    ///     by ``huffmanEncodedByteLength(of:)``. Passing anything else is a
    ///     programmer error; too small a value would overrun the buffer.
    /// - Returns: The number of bytes used while encoding the string.
    @available(anyAppleOS 26.0, *)
    @discardableResult
    mutating func setHuffmanEncoded(
        bytes stringBytes: some Collection<UInt8>,
        encodedByteLength: Int
    ) -> Int {
        assert(encodedByteLength == ByteBuffer.huffmanEncodedByteLength(of: stringBytes))
        self.ensureBytesAvailable(encodedByteLength)

        return self.withUnsafeMutableWritableBytes { bytes in
            var state = _EncoderState()

            for byte in stringBytes {
                ByteBuffer.writeHuffmanEntry(entry: HuffmanEncoderTable[byte], state: &state, bytes: bytes)
            }

            if state.remainingBits > 0 && state.remainingBits < 8 {
                // set all remaining bits of the last byte to 1
                bytes[state.offset] |= UInt8(1 << state.remainingBits) - 1
                state.offset += 1
                state.remainingBits = (state.offset == bytes.count ? 0 : 8)
            }

            return state.offset
        }
    }

    @available(anyAppleOS 26.0, *)
    @discardableResult
    mutating func writeHuffmanEncoded(
        bytes stringBytes: some Collection<UInt8>,
        encodedByteLength: Int
    ) -> Int {
        let written = self.setHuffmanEncoded(bytes: stringBytes, encodedByteLength: encodedByteLength)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    fileprivate static func writeHuffmanEntry(
        entry: HuffmanEncodeEntry,
        state: inout _EncoderState,
        bytes: UnsafeMutableRawBufferPointer
    ) {
        // will it fit as-is?
        if entry.nbits == state.remainingBits {
            bytes[state.offset] |= UInt8(entry.bits)
            state.offset += 1
            state.remainingBits = state.offset == bytes.count ? 0 : 8
        } else if entry.nbits < state.remainingBits {
            let diff = state.remainingBits - entry.nbits
            bytes[state.offset] |= UInt8(entry.bits << diff)
            state.remainingBits -= entry.nbits
        } else {
            var code = entry.bits
            var nbits = entry.nbits

            nbits -= state.remainingBits
            bytes[state.offset] |= UInt8(code >> nbits)
            state.offset += 1

            if nbits & 0x7 != 0 {
                // align code to MSB
                code <<= 8 - (nbits & 0x7)
            }

            // we can short-circuit if less than 8 bits are remaining
            if nbits < 8 {
                bytes[state.offset] = UInt8(truncatingIfNeeded: code)
                state.remainingBits = 8 - nbits
                return
            }

            // longer path for larger amounts
            switch nbits {
            case _ where nbits > 24:
                bytes[state.offset] = UInt8(truncatingIfNeeded: code >> 24)
                nbits -= 8
                state.offset += 1
                fallthrough
            case _ where nbits > 16:
                bytes[state.offset] = UInt8(truncatingIfNeeded: code >> 16)
                nbits -= 8
                state.offset += 1
                fallthrough
            case _ where nbits > 8:
                bytes[state.offset] = UInt8(truncatingIfNeeded: code >> 8)
                nbits -= 8
                state.offset += 1
            default:
                break
            }

            if nbits == 8 {
                bytes[state.offset] = UInt8(truncatingIfNeeded: code)
                state.offset += 1
                state.remainingBits = state.offset == bytes.count ? 0 : 8
            } else {
                state.remainingBits = 8 - nbits
                bytes[state.offset] = UInt8(truncatingIfNeeded: code)
            }
        }
    }

    private mutating func ensureBytesAvailable(_ bytesNeeded: Int) {
        if bytesNeeded <= self.writableBytes {
            // just zero the requested number of bytes before we start OR-ing in our values
            self.withUnsafeMutableWritableBytes { ptr in
                ptr.copyBytes(from: repeatElement(0, count: bytesNeeded))
            }
            return
        }

        let neededToAdd = bytesNeeded - self.writableBytes
        let newLength = self.capacity + neededToAdd

        // reallocate to ensure we have the room we need
        self.reserveCapacity(newLength)

        // now zero all writable bytes that we expect to use
        self.withUnsafeMutableWritableBytes { ptr in
            ptr.copyBytes(from: repeatElement(0, count: bytesNeeded))
        }
    }

    /// The largest number of bytes that `encodedLength` Huffman-encoded octets can decode to.
    ///
    /// The shortest code in the QPACK Huffman table is 5 bits, so `encodedLength` octets carry
    /// `floor(encodedLength * 8 / 5)` symbols at most. We round up, which is one byte of slack
    /// at most and keeps the arithmetic obviously non-negative.
    ///
    /// This bound is load-bearing for memory safety, not just a heuristic: ``decodeHuffman(at:length:into:)``
    /// writes into its destination without bounds checks, relying on the destination having
    /// been sized with this function.
    fileprivate static func maxHuffmanDecodedLength(ofEncodedLength encodedLength: Int) -> Int {
        (encodedLength * 8 + 4) / 5
    }

    /// Decoded strings up to this many bytes long are decoded via a stack buffer, so that the
    /// resulting `String` can pick its own (possibly inline, allocation-free) storage. Chosen to
    /// cover every header name and all but the longest header values.
    fileprivate static let huffmanStackDecodeThreshold = 128

    /// Decodes a huffman-encoded string from the `ByteBuffer`.
    /// - Parameters:
    ///   - index: The location of the encoded bytes to read.
    ///   - length: The number of huffman-encoded octets to read.
    /// - Returns: The decoded `String`, or nil if it can't be read.
    @discardableResult
    @available(anyAppleOS 26.0, *)
    func getHuffmanEncodedString(at index: Int, length: Int) -> String? {
        let start = index - self.readerIndex
        guard start >= 0, start <= self.readableBytes, length >= 0, length <= self.readableBytes - start
        else {
            assertionFailure(
                "Requested range out of bounds: \(index) + \(length) vs. \(self.readerIndex)..<\(self.writerIndex)"
            )
            return nil
        }
        if length == 0 {
            return ""
        }

        let maxDecodedLength = Self.maxHuffmanDecodedLength(ofEncodedLength: length)

        if maxDecodedLength <= Self.huffmanStackDecodeThreshold {
            // Decode into a stack buffer and then hand the exact byte count to `String`, so short
            // results can live inline in the `String` rather than forcing a heap allocation.
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: maxDecodedLength) { scratch in
                guard let count = self.decodeHuffman(at: index, length: length, into: scratch) else {
                    return nil
                }
                return String(decoding: scratch[..<count], as: UTF8.self)
            }
        }

        // For long values, decode straight into the `String`'s storage rather than paying for a
        // scratch buffer plus a copy. This over-reserves by up to 1.6x, but such values are far
        // beyond the inline-storage limit anyway, so the allocation was unavoidable.
        return try? String(unsafeUninitializedCapacity: maxDecodedLength) { backingStorage in
            guard let count = self.decodeHuffman(at: index, length: length, into: backingStorage) else {
                throw HuffmanDecodeError.invalidState
            }
            return count
        }
    }

    /// Decode `length` Huffman-encoded octets starting at `index` into `destination`.
    ///
    /// - Precondition: `index..<index + length` must lie within the readable bytes; the caller is
    ///   expected to have validated that.
    /// - Precondition: `destination` must have room for
    ///   ``maxHuffmanDecodedLength(ofEncodedLength:)`` bytes; the writes below are unchecked.
    /// - Returns: The number of bytes decoded, or `nil` if the input is not a valid Huffman
    ///   encoding.
    @available(anyAppleOS 26.0, *)
    private func decodeHuffman(
        at index: Int,
        length: Int,
        into destination: UnsafeMutableBufferPointer<UInt8>
    ) -> Int? {
        assert(destination.count >= Self.maxHuffmanDecodedLength(ofEncodedLength: length))

        let start = index - self.readerIndex
        let span = self.readableBytesUInt8Span.extracting(start..<(start &+ length))

        var state: UInt8 = 0

        // We do unchecked math on offset. Every symbol emitted consumes at least 5 bits of the
        // `length * 8` bits of input, so offset cannot exceed `maxHuffmanDecodedLength(ofEncodedLength: length)`,
        // which is the asserted size of `destination`.
        var offset = 0
        var acceptable = false

        // TODO: Move to `for ch in span` once we can require an anyAppleOS( 27.0, *)
        for i in span.indices {
            let ch = span[i]
            var t = HuffmanDecoderTable[state: state, nybble: ch >> 4]
            if t.flags.contains(.failure) {
                return nil
            }
            if t.flags.contains(.symbol) {
                destination[offset] = t.sym
                offset &+= 1
            }

            t = HuffmanDecoderTable[state: t.state, nybble: ch & 0xf]
            if t.flags.contains(.failure) {
                return nil
            }
            if t.flags.contains(.symbol) {
                destination[offset] = t.sym
                offset &+= 1
            }

            state = t.state
            acceptable = t.flags.contains(.accepted)
        }

        guard acceptable else {
            return nil
        }

        return offset
    }
}

private enum HuffmanDecodeError: Error {
    /// The decoder entered an invalid state. Usually this means invalid input.
    case invalidState
}
