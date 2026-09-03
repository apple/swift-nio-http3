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
    fileprivate static func huffmanEncodedBitLength(of bytes: some Collection<UInt8>) -> Int {
        let numberOfBits = bytes.reduce(0) { $0 + staticHuffmanTable[Int($1)].nbits }
        // round up to nearest multiple of 8 for EOS prefix
        return (numberOfBits + 7) & ~7
    }

    /// Returns the number of bytes required to encode a given string.
    static func huffmanEncodedByteLength(of bytes: some Collection<UInt8>) -> Int {
        self.huffmanEncodedBitLength(of: bytes) / 8
    }

    /// Encodes the given string to the buffer, using QPACK Huffman encoding.
    ///
    /// - Parameter stringBytes: The string data to encode.
    /// - Returns: The number of bytes used while encoding the string.
    @discardableResult
    mutating func setHuffmanEncoded(bytes stringBytes: some Collection<UInt8>) -> Int {
        let clen = ByteBuffer.huffmanEncodedBitLength(of: stringBytes)
        self.ensureBitsAvailable(clen)

        return self.withUnsafeMutableWritableBytes { bytes in
            var state = _EncoderState()

            for byte in stringBytes {
                ByteBuffer.writeHuffmanEntry(entry: staticHuffmanTable[Int(byte)], state: &state, bytes: bytes)
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

    @discardableResult
    mutating func writeHuffmanEncoded(bytes stringBytes: some Collection<UInt8>) -> Int {
        let written = self.setHuffmanEncoded(bytes: stringBytes)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    fileprivate static func writeHuffmanEntry(
        entry: HuffmanTableEntry,
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
            var (code, nbits) = entry

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

    private mutating func ensureBitsAvailable(_ bits: Int) {
        let bytesNeeded = bits / 8
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

    /// Decodes a huffman-encoded string from the `ByteBuffer`.
    /// - Parameters:
    ///   - index: The location of the encoded bytes to read.
    ///   - length: The number of huffman-encoded octets to read.
    /// - Returns: The decoded `String`, or nil if it can't be read.
    @discardableResult
    func getHuffmanEncodedString(at index: Int, length: Int) -> String? {
        if index + length > self.capacity {
            assertionFailure(
                "Requested range out of bounds: \(index..<index + length) vs. \(self.capacity)"
            )
            return nil
        }
        if length == 0 {
            return ""
        }

        let capacity = length * QPACKConstants.huffmanMaxCompressionRatio

        return try? String(unsafeUninitializedCapacity: capacity) { backingStorage in
            var state: UInt8 = 0

            // We do unchecked math on offset. Offset is strictly unable to get any larger than `length * 2`,
            // and we already did checked multiplication on that value.
            var offset = 0
            var acceptable = false

            // We force-unwrap here to crash if we attempt to decode out of bounds.
            for ch in self.viewBytes(at: index, length: length)! {
                var t = HuffmanDecoderTable.shared[state: state, nybble: ch >> 4]
                if t.flags.contains(.failure) {
                    throw HuffmanDecodeError.invalidState
                }
                if t.flags.contains(.symbol) {
                    backingStorage[offset] = t.sym
                    offset &+= 1
                }

                t = HuffmanDecoderTable.shared[state: t.state, nybble: ch & 0xf]
                if t.flags.contains(.failure) {
                    throw HuffmanDecodeError.invalidState
                }
                if t.flags.contains(.symbol) {
                    backingStorage[offset] = t.sym
                    offset &+= 1
                }

                state = t.state
                acceptable = t.flags.contains(.accepted)
            }

            guard acceptable else {
                throw HuffmanDecodeError.invalidState
            }

            return offset
        }
    }
}

private enum HuffmanDecodeError: Error {
    /// The decoder entered an invalid state. Usually this means invalid input.
    case invalidState
}
