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

typealias HuffmanTableEntry = (bits: UInt32, nbits: Int)

/// Base-64 decoding has been jovially purloined from swift-corelibs-foundation/.../NSData.swift.
/// The ranges of ASCII characters that are used to encode data in Base64.
private let base64ByteMappings: [Range<UInt8>] = [
    65..<91,  // A-Z
    97..<123,  // a-z
    48..<58,  // 0-9
    43..<44,  // +
    47..<48,  // /
]
/**
 Padding character used when the number of bytes to encode is not divisible by 3
 */
// =
private let base64Padding: UInt8 = 61

/// This method takes a byte with a character from Base64-encoded string
/// and gets the binary value that the character corresponds to.
///
/// - parameter byte:       The byte with the Base64 character.
/// - returns:              Base64DecodedByte value containing the result (Valid , Invalid, Padding).
private enum Base64DecodedByte {
    case valid(UInt8)
    case invalid
    case padding
}

private func base64DecodeByte(_ byte: UInt8) -> Base64DecodedByte {
    guard byte != base64Padding else { return .padding }
    var decodedStart: UInt8 = 0
    for range in base64ByteMappings {
        if range.contains(byte) {
            let result = decodedStart + (byte - range.lowerBound)
            return .valid(result)
        }
        decodedStart += range.upperBound - range.lowerBound
    }
    return .invalid
}

/// This method decodes Base64-encoded data.
///
/// If the input contains any bytes that are not valid Base64 characters, and `ignoreUnknownCharacters` is true,
/// this will return nil.
///
/// - Parameters:
///   - bytes: The Base64 bytes.
///   - ignoreUnknownCharacters: Whether to ignore unknown characters.
/// - Returns: The decoded bytes.
private func base64DecodeBytes(_ bytes: some Collection<UInt8>, ignoreUnknownCharacters: Bool = false) -> [UInt8]? {
    var decodedBytes = [UInt8]()
    decodedBytes.reserveCapacity((bytes.count / 3) * 2)

    var currentByte: UInt8 = 0
    var validCharacterCount = 0
    var paddingCount = 0
    var index = 0

    for base64Char in bytes {
        let value: UInt8

        switch base64DecodeByte(base64Char) {
        case .valid(let v):
            value = v
            validCharacterCount += 1
        case .invalid:
            if ignoreUnknownCharacters {
                continue
            } else {
                return nil
            }
        case .padding:
            paddingCount += 1
            continue
        }

        // padding found in the middle of the sequence is invalid
        if paddingCount > 0 {
            return nil
        }

        switch index % 4 {
        case 0:
            currentByte = (value << 2)
        case 1:
            currentByte |= (value >> 4)
            decodedBytes.append(currentByte)
            currentByte = (value << 4)
        case 2:
            currentByte |= (value >> 2)
            decodedBytes.append(currentByte)
            currentByte = (value << 6)
        case 3:
            currentByte |= value
            decodedBytes.append(currentByte)
        default:
            fatalError()
        }

        index += 1
    }

    guard (validCharacterCount + paddingCount) % 4 == 0 else {
        // invalid character count
        return nil
    }
    return decodedBytes
}

internal let staticHuffmanTable: [HuffmanTableEntry] = [
    (0x1ff8, 13), (0x7fffd8, 23), (0xfffffe2, 28), (0xfffffe3, 28), (0xfffffe4, 28), (0xfffffe5, 28),
    (0xfffffe6, 28), (0xfffffe7, 28), (0xfffffe8, 28), (0xffffea, 24), (0x3fff_fffc, 30), (0xfffffe9, 28),
    (0xfffffea, 28), (0x3fff_fffd, 30), (0xfffffeb, 28), (0xfffffec, 28), (0xfffffed, 28), (0xfffffee, 28),
    (0xfffffef, 28), (0xffffff0, 28), (0xffffff1, 28), (0xffffff2, 28), (0x3fff_fffe, 30), (0xffffff3, 28),
    (0xffffff4, 28), (0xffffff5, 28), (0xffffff6, 28), (0xffffff7, 28), (0xffffff8, 28), (0xffffff9, 28),
    (0xffffffa, 28), (0xffffffb, 28), (0x14, 6), (0x3f8, 10), (0x3f9, 10), (0xffa, 12),
    (0x1ff9, 13), (0x15, 6), (0xf8, 8), (0x7fa, 11), (0x3fa, 10), (0x3fb, 10),
    (0xf9, 8), (0x7fb, 11), (0xfa, 8), (0x16, 6), (0x17, 6), (0x18, 6),
    (0x0, 5), (0x1, 5), (0x2, 5), (0x19, 6), (0x1a, 6), (0x1b, 6),
    (0x1c, 6), (0x1d, 6), (0x1e, 6), (0x1f, 6), (0x5c, 7), (0xfb, 8),
    (0x7ffc, 15), (0x20, 6), (0xffb, 12), (0x3fc, 10), (0x1ffa, 13), (0x21, 6),
    (0x5d, 7), (0x5e, 7), (0x5f, 7), (0x60, 7), (0x61, 7), (0x62, 7),
    (0x63, 7), (0x64, 7), (0x65, 7), (0x66, 7), (0x67, 7), (0x68, 7),
    (0x69, 7), (0x6a, 7), (0x6b, 7), (0x6c, 7), (0x6d, 7), (0x6e, 7),
    (0x6f, 7), (0x70, 7), (0x71, 7), (0x72, 7), (0xfc, 8), (0x73, 7),
    (0xfd, 8), (0x1ffb, 13), (0x7fff0, 19), (0x1ffc, 13), (0x3ffc, 14), (0x22, 6),
    (0x7ffd, 15), (0x3, 5), (0x23, 6), (0x4, 5), (0x24, 6), (0x5, 5),
    (0x25, 6), (0x26, 6), (0x27, 6), (0x6, 5), (0x74, 7), (0x75, 7),
    (0x28, 6), (0x29, 6), (0x2a, 6), (0x7, 5), (0x2b, 6), (0x76, 7),
    (0x2c, 6), (0x8, 5), (0x9, 5), (0x2d, 6), (0x77, 7), (0x78, 7),
    (0x79, 7), (0x7a, 7), (0x7b, 7), (0x7ffe, 15), (0x7fc, 11), (0x3ffd, 14),
    (0x1ffd, 13), (0xffffffc, 28), (0xfffe6, 20), (0x3fffd2, 22), (0xfffe7, 20), (0xfffe8, 20),
    (0x3fffd3, 22), (0x3fffd4, 22), (0x3fffd5, 22), (0x7fffd9, 23), (0x3fffd6, 22), (0x7fffda, 23),
    (0x7fffdb, 23), (0x7fffdc, 23), (0x7fffdd, 23), (0x7fffde, 23), (0xffffeb, 24), (0x7fffdf, 23),
    (0xffffec, 24), (0xffffed, 24), (0x3fffd7, 22), (0x7fffe0, 23), (0xffffee, 24), (0x7fffe1, 23),
    (0x7fffe2, 23), (0x7fffe3, 23), (0x7fffe4, 23), (0x1fffdc, 21), (0x3fffd8, 22), (0x7fffe5, 23),
    (0x3fffd9, 22), (0x7fffe6, 23), (0x7fffe7, 23), (0xffffef, 24), (0x3fffda, 22), (0x1fffdd, 21),
    (0xfffe9, 20), (0x3fffdb, 22), (0x3fffdc, 22), (0x7fffe8, 23), (0x7fffe9, 23), (0x1fffde, 21),
    (0x7fffea, 23), (0x3fffdd, 22), (0x3fffde, 22), (0xfffff0, 24), (0x1fffdf, 21), (0x3fffdf, 22),
    (0x7fffeb, 23), (0x7fffec, 23), (0x1fffe0, 21), (0x1fffe1, 21), (0x3fffe0, 22), (0x1fffe2, 21),
    (0x7fffed, 23), (0x3fffe1, 22), (0x7fffee, 23), (0x7fffef, 23), (0xfffea, 20), (0x3fffe2, 22),
    (0x3fffe3, 22), (0x3fffe4, 22), (0x7ffff0, 23), (0x3fffe5, 22), (0x3fffe6, 22), (0x7ffff1, 23),
    (0x3ffffe0, 26), (0x3ffffe1, 26), (0xfffeb, 20), (0x7fff1, 19), (0x3fffe7, 22), (0x7ffff2, 23),
    (0x3fffe8, 22), (0x1ffffec, 25), (0x3ffffe2, 26), (0x3ffffe3, 26), (0x3ffffe4, 26), (0x7ffffde, 27),
    (0x7ffffdf, 27), (0x3ffffe5, 26), (0xfffff1, 24), (0x1ffffed, 25), (0x7fff2, 19), (0x1fffe3, 21),
    (0x3ffffe6, 26), (0x7ffffe0, 27), (0x7ffffe1, 27), (0x3ffffe7, 26), (0x7ffffe2, 27), (0xfffff2, 24),
    (0x1fffe4, 21), (0x1fffe5, 21), (0x3ffffe8, 26), (0x3ffffe9, 26), (0xffffffd, 28), (0x7ffffe3, 27),
    (0x7ffffe4, 27), (0x7ffffe5, 27), (0xfffec, 20), (0xfffff3, 24), (0xfffed, 20), (0x1fffe6, 21),
    (0x3fffe9, 22), (0x1fffe7, 21), (0x1fffe8, 21), (0x7ffff3, 23), (0x3fffea, 22), (0x3fffeb, 22),
    (0x1ffffee, 25), (0x1ffffef, 25), (0xfffff4, 24), (0xfffff5, 24), (0x3ffffea, 26), (0x7ffff4, 23),
    (0x3ffffeb, 26), (0x7ffffe6, 27), (0x3ffffec, 26), (0x3ffffed, 26), (0x7ffffe7, 27), (0x7ffffe8, 27),
    (0x7ffffe9, 27), (0x7ffffea, 27), (0x7ffffeb, 27), (0xffffffe, 28), (0x7ffffec, 27), (0x7ffffed, 27),
    (0x7ffffee, 27), (0x7ffffef, 27), (0x7fffff0, 27), (0x3ffffee, 26), (0x3fff_ffff, 30),
]

// Great googly-moogly that's a large array! This comes from the nice folks at nghttp.

// This implementation of a Huffman decoding table for HTTP/3 is essentially a
// Swift port of the C tables from nghttp2's Huffman decoding implementation,
// and is thus clearly a derivative work of the nghttp2 file
// ``nghttp2_hd_huffman_data.c``, obtained from https://github.com/tatsuhiro-t/nghttp2/.
// That work is also available under the Apache 2.0 license under the following terms:
//
// Copyright (c) 2013 Tatsuhiro Tsujikawa
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

typealias HuffmanDecodeEntry = (state: UInt8, flags: HuffmanDecoderFlags, sym: UInt8)

internal struct HuffmanDecoderFlags: OptionSet {
    var rawValue: UInt8

    static var accepted: HuffmanDecoderFlags { Self(rawValue: 0b001) }
    static var symbol: HuffmanDecoderFlags { Self(rawValue: 0b010) }
    static var failure: HuffmanDecoderFlags { Self(rawValue: 0b100) }
}

/// This was described nicely by `@Lukasa` in his Python implementation:
///
/// The essence of this approach is that it builds a finite state machine out of
/// 4-bit nybbles of Huffman coded data. The input function passes 4 bits worth of
/// data to the state machine each time, which uses those 4 bits of data along with
/// the current accumulated state data to process the data given.
///
/// For the sake of efficiency, the in-memory representation of the states,
/// transitions, and result values of the state machine are represented as a long
/// list containing three-tuples. This list is enormously long, and viewing it as
/// an in-memory representation is not very clear, but it is laid out here in a way
/// that is intended to be *somewhat* more clear.
///
/// Essentially, the list is structured as 256 collections of 16 entries (one for
/// each nybble) of three-tuples. Each collection is called a "node", and the
/// zeroth collection is called the "root node". The state machine tracks one
/// value: the "state" byte.
///
/// For each nybble passed to the state machine, it first multiplies the "state"
/// byte by 16 and adds the numerical value of the nybble. This number is the index
/// into the large flat list.
///
/// The three-tuple that is found by looking up that index consists of three
/// values:
///
/// - a new state value, used for subsequent decoding
/// - a collection of flags, used to determine whether data is emitted or whether
/// the state machine is complete.
/// - the byte value to emit, assuming that emitting a byte is required.
///
/// The flags are consulted, if necessary a byte is emitted, and then the next
/// nybble is used. This continues until the state machine believes it has
/// completely Huffman-decoded the data.
///
/// This approach has relatively little indirection, and therefore performs
/// relatively well. The total number of loop
/// iterations is 4x the number of bytes passed to the decoder.
internal struct HuffmanDecoderTable {
    static let shared = HuffmanDecoderTable()

    subscript(state state: UInt8, nybble nybble: UInt8) -> HuffmanDecodeEntry {
        assert(nybble < 16)
        let index = (Int(state) * 16) + Int(nybble)
        return HuffmanDecoderTable.rawTable[index]
    }

    private static let rawTable: [HuffmanDecodeEntry] = {
        let base64_table_bytes: StaticString = """
            BAAABQAABwAACAAACwAADAAAEAAAEwAAGQAAHAAAIAAAIwAAKgAAMQAAOQAAQAEA
            AAMwAAMxAAMyAANhAANjAANlAANpAANvAANzAAN0DQAADgAAEQAAEgAAFAAAFQAA
            AQIwFgMwAQIxFgMxAQIyFgMyAQJhFgNhAQJjFgNjAQJlFgNlAQJpFgNpAQJvFgNv
            AgIwCQIwFwIwKAMwAgIxCQIxFwIxKAMxAgIyCQIyFwIyKAMyAgJhCQJhFwJhKANh
            AwIwBgIwCgIwDwIwGAIwHwIwKQIwOAMwAwIxBgIxCgIxDwIxGAIxHwIxKQIxOAMx
            AwIyBgIyCgIyDwIyGAIyHwIyKQIyOAMyAwJhBgJhCgJhDwJhGAJhHwJhKQJhOANh
            AgJjCQJjFwJjKANjAgJlCQJlFwJlKANlAgJpCQJpFwJpKANpAgJvCQJvFwJvKANv
            AwJjBgJjCgJjDwJjGAJjHwJjKQJjOANjAwJlBgJlCgJlDwJlGAJlHwJlKQJlOANl
            AwJpBgJpCgJpDwJpGAJpHwJpKQJpOANpAwJvBgJvCgJvDwJvGAJvHwJvKQJvOANv
            AQJzFgNzAQJ0FgN0AAMgAAMlAAMtAAMuAAMvAAMzAAM0AAM1AAM2AAM3AAM4AAM5
            AgJzCQJzFwJzKANzAgJ0CQJ0FwJ0KAN0AQIgFgMgAQIlFgMlAQItFgMtAQIuFgMu
            AwJzBgJzCgJzDwJzGAJzHwJzKQJzOANzAwJ0BgJ0CgJ0DwJ0GAJ0HwJ0KQJ0OAN0
            AgIgCQIgFwIgKAMgAgIlCQIlFwIlKAMlAgItCQItFwItKAMtAgIuCQIuFwIuKAMu
            AwIgBgIgCgIgDwIgGAIgHwIgKQIgOAMgAwIlBgIlCgIlDwIlGAIlHwIlKQIlOAMl
            AwItBgItCgItDwItGAItHwItKQItOAMtAwIuBgIuCgIuDwIuGAIuHwIuKQIuOAMu
            AQIvFgMvAQIzFgMzAQI0FgM0AQI1FgM1AQI2FgM2AQI3FgM3AQI4FgM4AQI5FgM5
            AgIvCQIvFwIvKAMvAgIzCQIzFwIzKAMzAgI0CQI0FwI0KAM0AgI1CQI1FwI1KAM1
            AwIvBgIvCgIvDwIvGAIvHwIvKQIvOAMvAwIzBgIzCgIzDwIzGAIzHwIzKQIzOAMz
            AwI0BgI0CgI0DwI0GAI0HwI0KQI0OAM0AwI1BgI1CgI1DwI1GAI1HwI1KQI1OAM1
            AgI2CQI2FwI2KAM2AgI3CQI3FwI3KAM3AgI4CQI4FwI4KAM4AgI5CQI5FwI5KAM5
            AwI2BgI2CgI2DwI2GAI2HwI2KQI2OAM2AwI3BgI3CgI3DwI3GAI3HwI3KQI3OAM3
            AwI4BgI4CgI4DwI4GAI4HwI4KQI4OAM4AwI5BgI5CgI5DwI5GAI5HwI5KQI5OAM5
            GgAAGwAAHQAAHgAAIQAAIgAAJAAAJQAAKwAALgAAMgAANQAAOgAAPQAAQQAARAEA
            AAM9AANBAANfAANiAANkAANmAANnAANoAANsAANtAANuAANwAANyAAN1JgAAJwAA
            AQI9FgM9AQJBFgNBAQJfFgNfAQJiFgNiAQJkFgNkAQJmFgNmAQJnFgNnAQJoFgNo
            AgI9CQI9FwI9KAM9AgJBCQJBFwJBKANBAgJfCQJfFwJfKANfAgJiCQJiFwJiKANi
            AwI9BgI9CgI9DwI9GAI9HwI9KQI9OAM9AwJBBgJBCgJBDwJBGAJBHwJBKQJBOANB
            AwJfBgJfCgJfDwJfGAJfHwJfKQJfOANfAwJiBgJiCgJiDwJiGAJiHwJiKQJiOANi
            AgJkCQJkFwJkKANkAgJmCQJmFwJmKANmAgJnCQJnFwJnKANnAgJoCQJoFwJoKANo
            AwJkBgJkCgJkDwJkGAJkHwJkKQJkOANkAwJmBgJmCgJmDwJmGAJmHwJmKQJmOANm
            AwJnBgJnCgJnDwJnGAJnHwJnKQJnOANnAwJoBgJoCgJoDwJoGAJoHwJoKQJoOANo
            AQJsFgNsAQJtFgNtAQJuFgNuAQJwFgNwAQJyFgNyAQJ1FgN1AAM6AANCAANDAANE
            AgJsCQJsFwJsKANsAgJtCQJtFwJtKANtAgJuCQJuFwJuKANuAgJwCQJwFwJwKANw
            AwJsBgJsCgJsDwJsGAJsHwJsKQJsOANsAwJtBgJtCgJtDwJtGAJtHwJtKQJtOANt
            AwJuBgJuCgJuDwJuGAJuHwJuKQJuOANuAwJwBgJwCgJwDwJwGAJwHwJwKQJwOANw
            AgJyCQJyFwJyKANyAgJ1CQJ1FwJ1KAN1AQI6FgM6AQJCFgNCAQJDFgNDAQJEFgNE
            AwJyBgJyCgJyDwJyGAJyHwJyKQJyOANyAwJ1BgJ1CgJ1DwJ1GAJ1HwJ1KQJ1OAN1
            AgI6CQI6FwI6KAM6AgJCCQJCFwJCKANCAgJDCQJDFwJDKANDAgJECQJEFwJEKANE
            AwI6BgI6CgI6DwI6GAI6HwI6KQI6OAM6AwJCBgJCCgJCDwJCGAJCHwJCKQJCOANC
            AwJDBgJDCgJDDwJDGAJDHwJDKQJDOANDAwJEBgJECgJEDwJEGAJEHwJEKQJEOANE
            LAAALQAALwAAMAAAMwAANAAANgAANwAAOwAAPAAAPgAAPwAAQgAAQwAARQAASAEA
            AANFAANGAANHAANIAANJAANKAANLAANMAANNAANOAANPAANQAANRAANSAANTAANU
            AQJFFgNFAQJGFgNGAQJHFgNHAQJIFgNIAQJJFgNJAQJKFgNKAQJLFgNLAQJMFgNM
            AgJFCQJFFwJFKANFAgJGCQJGFwJGKANGAgJHCQJHFwJHKANHAgJICQJIFwJIKANI
            AwJFBgJFCgJFDwJFGAJFHwJFKQJFOANFAwJGBgJGCgJGDwJGGAJGHwJGKQJGOANG
            AwJHBgJHCgJHDwJHGAJHHwJHKQJHOANHAwJIBgJICgJIDwJIGAJIHwJIKQJIOANI
            AgJJCQJJFwJJKANJAgJKCQJKFwJKKANKAgJLCQJLFwJLKANLAgJMCQJMFwJMKANM
            AwJJBgJJCgJJDwJJGAJJHwJJKQJJOANJAwJKBgJKCgJKDwJKGAJKHwJKKQJKOANK
            AwJLBgJLCgJLDwJLGAJLHwJLKQJLOANLAwJMBgJMCgJMDwJMGAJMHwJMKQJMOANM
            AQJNFgNNAQJOFgNOAQJPFgNPAQJQFgNQAQJRFgNRAQJSFgNSAQJTFgNTAQJUFgNU
            AgJNCQJNFwJNKANNAgJOCQJOFwJOKANOAgJPCQJPFwJPKANPAgJQCQJQFwJQKANQ
            AwJNBgJNCgJNDwJNGAJNHwJNKQJNOANNAwJOBgJOCgJODwJOGAJOHwJOKQJOOANO
            AwJPBgJPCgJPDwJPGAJPHwJPKQJPOANPAwJQBgJQCgJQDwJQGAJQHwJQKQJQOANQ
            AgJRCQJRFwJRKANRAgJSCQJSFwJSKANSAgJTCQJTFwJTKANTAgJUCQJUFwJUKANU
            AwJRBgJRCgJRDwJRGAJRHwJRKQJROANRAwJSBgJSCgJSDwJSGAJSHwJSKQJSOANS
            AwJTBgJTCgJTDwJTGAJTHwJTKQJTOANTAwJUBgJUCgJUDwJUGAJUHwJUKQJUOANU
            AANVAANWAANXAANZAANqAANrAANxAAN2AAN3AAN4AAN5AAN6RgAARwAASQAASgEA
            AQJVFgNVAQJWFgNWAQJXFgNXAQJZFgNZAQJqFgNqAQJrFgNrAQJxFgNxAQJ2FgN2
            AgJVCQJVFwJVKANVAgJWCQJWFwJWKANWAgJXCQJXFwJXKANXAgJZCQJZFwJZKANZ
            AwJVBgJVCgJVDwJVGAJVHwJVKQJVOANVAwJWBgJWCgJWDwJWGAJWHwJWKQJWOANW
            AwJXBgJXCgJXDwJXGAJXHwJXKQJXOANXAwJZBgJZCgJZDwJZGAJZHwJZKQJZOANZ
            AgJqCQJqFwJqKANqAgJrCQJrFwJrKANrAgJxCQJxFwJxKANxAgJ2CQJ2FwJ2KAN2
            AwJqBgJqCgJqDwJqGAJqHwJqKQJqOANqAwJrBgJrCgJrDwJrGAJrHwJrKQJrOANr
            AwJxBgJxCgJxDwJxGAJxHwJxKQJxOANxAwJ2BgJ2CgJ2DwJ2GAJ2HwJ2KQJ2OAN2
            AQJ3FgN3AQJ4FgN4AQJ5FgN5AQJ6FgN6AAMmAAMqAAMsAAM7AANYAANaSwAATgAA
            AgJ3CQJ3FwJ3KAN3AgJ4CQJ4FwJ4KAN4AgJ5CQJ5FwJ5KAN5AgJ6CQJ6FwJ6KAN6
            AwJ3BgJ3CgJ3DwJ3GAJ3HwJ3KQJ3OAN3AwJ4BgJ4CgJ4DwJ4GAJ4HwJ4KQJ4OAN4
            AwJ5BgJ5CgJ5DwJ5GAJ5HwJ5KQJ5OAN5AwJ6BgJ6CgJ6DwJ6GAJ6HwJ6KQJ6OAN6
            AQImFgMmAQIqFgMqAQIsFgMsAQI7FgM7AQJYFgNYAQJaFgNaTAAATQAATwAAUQAA
            AgImCQImFwImKAMmAgIqCQIqFwIqKAMqAgIsCQIsFwIsKAMsAgI7CQI7FwI7KAM7
            AwImBgImCgImDwImGAImHwImKQImOAMmAwIqBgIqCgIqDwIqGAIqHwIqKQIqOAMq
            AwIsBgIsCgIsDwIsGAIsHwIsKQIsOAMsAwI7BgI7CgI7DwI7GAI7HwI7KQI7OAM7
            AgJYCQJYFwJYKANYAgJaCQJaFwJaKANaAAMhAAMiAAMoAAMpAAM/UAAAUgAAVAAA
            AwJYBgJYCgJYDwJYGAJYHwJYKQJYOANYAwJaBgJaCgJaDwJaGAJaHwJaKQJaOANa
            AQIhFgMhAQIiFgMiAQIoFgMoAQIpFgMpAQI/FgM/AAMnAAMrAAN8UwAAVQAAWAAA
            AgIhCQIhFwIhKAMhAgIiCQIiFwIiKAMiAgIoCQIoFwIoKAMoAgIpCQIpFwIpKAMp
            AwIhBgIhCgIhDwIhGAIhHwIhKQIhOAMhAwIiBgIiCgIiDwIiGAIiHwIiKQIiOAMi
            AwIoBgIoCgIoDwIoGAIoHwIoKQIoOAMoAwIpBgIpCgIpDwIpGAIpHwIpKQIpOAMp
            AgI/CQI/FwI/KAM/AQInFgMnAQIrFgMrAQJ8FgN8AAMjAAM+VgAAVwAAWQAAWgAA
            AwI/BgI/CgI/DwI/GAI/HwI/KQI/OAM/AgInCQInFwInKAMnAgIrCQIrFwIrKAMr
            AwInBgInCgInDwInGAInHwInKQInOAMnAwIrBgIrCgIrDwIrGAIrHwIrKQIrOAMr
            AgJ8CQJ8FwJ8KAN8AQIjFgMjAQI+FgM+AAMAAAMkAANAAANbAANdAAN+WwAAXAAA
            AwJ8BgJ8CgJ8DwJ8GAJ8HwJ8KQJ8OAN8AgIjCQIjFwIjKAMjAgI+CQI+FwI+KAM+
            AwIjBgIjCgIjDwIjGAIjHwIjKQIjOAMjAwI+BgI+CgI+DwI+GAI+HwI+KQI+OAM+
            AQIAFgMAAQIkFgMkAQJAFgNAAQJbFgNbAQJdFgNdAQJ+FgN+AANeAAN9XQAAXgAA
            AgIACQIAFwIAKAMAAgIkCQIkFwIkKAMkAgJACQJAFwJAKANAAgJbCQJbFwJbKANb
            AwIABgIACgIADwIAGAIAHwIAKQIAOAMAAwIkBgIkCgIkDwIkGAIkHwIkKQIkOAMk
            AwJABgJACgJADwJAGAJAHwJAKQJAOANAAwJbBgJbCgJbDwJbGAJbHwJbKQJbOANb
            AgJdCQJdFwJdKANdAgJ+CQJ+FwJ+KAN+AQJeFgNeAQJ9FgN9AAM8AANgAAN7XwAA
            AwJdBgJdCgJdDwJdGAJdHwJdKQJdOANdAwJ+BgJ+CgJ+DwJ+GAJ+HwJ+KQJ+OAN+
            AgJeCQJeFwJeKANeAgJ9CQJ9FwJ9KAN9AQI8FgM8AQJgFgNgAQJ7FgN7YAAAbgAA
            AwJeBgJeCgJeDwJeGAJeHwJeKQJeOANeAwJ9BgJ9CgJ9DwJ9GAJ9HwJ9KQJ9OAN9
            AgI8CQI8FwI8KAM8AgJgCQJgFwJgKANgAgJ7CQJ7FwJ7KAN7YQAAZQAAbwAAhQAA
            AwI8BgI8CgI8DwI8GAI8HwI8KQI8OAM8AwJgBgJgCgJgDwJgGAJgHwJgKQJgOANg
            AwJ7BgJ7CgJ7DwJ7GAJ7HwJ7KQJ7OAN7YgAAYwAAZgAAaQAAcAAAdwAAhgAAmQAA
            AANcAAPDAAPQZAAAZwAAaAAAagAAawAAcQAAdAAAeAAAfgAAhwAAjgAAmgAAqQAA
            AQJcFgNcAQLDFgPDAQLQFgPQAAOAAAOCAAODAAOiAAO4AAPCAAPgAAPibAAAbQAA
            AgJcCQJcFwJcKANcAgLDCQLDFwLDKAPDAgLQCQLQFwLQKAPQAQKAFgOAAQKCFgOC
            AwJcBgJcCgJcDwJcGAJcHwJcKQJcOANcAwLDBgLDCgLDDwLDGALDHwLDKQLDOAPD
            AwLQBgLQCgLQDwLQGALQHwLQKQLQOAPQAgKACQKAFwKAKAOAAgKCCQKCFwKCKAOC
            AwKABgKACgKADwKAGAKAHwKAKQKAOAOAAwKCBgKCCgKCDwKCGAKCHwKCKQKCOAOC
            AQKDFgODAQKiFgOiAQK4FgO4AQLCFgPCAQLgFgPgAQLiFgPiAAOZAAOhAAOnAAOs
            AgKDCQKDFwKDKAODAgKiCQKiFwKiKAOiAgK4CQK4FwK4KAO4AgLCCQLCFwLCKAPC
            AwKDBgKDCgKDDwKDGAKDHwKDKQKDOAODAwKiBgKiCgKiDwKiGAKiHwKiKQKiOAOi
            AwK4BgK4CgK4DwK4GAK4HwK4KQK4OAO4AwLCBgLCCgLCDwLCGALCHwLCKQLCOAPC
            AgLgCQLgFwLgKAPgAgLiCQLiFwLiKAPiAQKZFgOZAQKhFgOhAQKnFgOnAQKsFgOs
            AwLgBgLgCgLgDwLgGALgHwLgKQLgOAPgAwLiBgLiCgLiDwLiGALiHwLiKQLiOAPi
            AgKZCQKZFwKZKAOZAgKhCQKhFwKhKAOhAgKnCQKnFwKnKAOnAgKsCQKsFwKsKAOs
            AwKZBgKZCgKZDwKZGAKZHwKZKQKZOAOZAwKhBgKhCgKhDwKhGAKhHwKhKQKhOAOh
            AwKnBgKnCgKnDwKnGAKnHwKnKQKnOAOnAwKsBgKsCgKsDwKsGAKsHwKsKQKsOAOs
            cgAAcwAAdQAAdgAAeQAAewAAfwAAggAAiAAAiwAAjwAAkgAAmwAAogAAqgAAtAAA
            AAOwAAOxAAOzAAPRAAPYAAPZAAPjAAPlAAPmegAAfAAAfQAAgAAAgQAAgwAAhAAA
            AQKwFgOwAQKxFgOxAQKzFgOzAQLRFgPRAQLYFgPYAQLZFgPZAQLjFgPjAQLlFgPl
            AgKwCQKwFwKwKAOwAgKxCQKxFwKxKAOxAgKzCQKzFwKzKAOzAgLRCQLRFwLRKAPR
            AwKwBgKwCgKwDwKwGAKwHwKwKQKwOAOwAwKxBgKxCgKxDwKxGAKxHwKxKQKxOAOx
            AwKzBgKzCgKzDwKzGAKzHwKzKQKzOAOzAwLRBgLRCgLRDwLRGALRHwLRKQLROAPR
            AgLYCQLYFwLYKAPYAgLZCQLZFwLZKAPZAgLjCQLjFwLjKAPjAgLlCQLlFwLlKAPl
            AwLYBgLYCgLYDwLYGALYHwLYKQLYOAPYAwLZBgLZCgLZDwLZGALZHwLZKQLZOAPZ
            AwLjBgLjCgLjDwLjGALjHwLjKQLjOAPjAwLlBgLlCgLlDwLlGALlHwLlKQLlOAPl
            AQLmFgPmAAOBAAOEAAOFAAOGAAOIAAOSAAOaAAOcAAOgAAOjAAOkAAOpAAOqAAOt
            AgLmCQLmFwLmKAPmAQKBFgOBAQKEFgOEAQKFFgOFAQKGFgOGAQKIFgOIAQKSFgOS
            AwLmBgLmCgLmDwLmGALmHwLmKQLmOAPmAgKBCQKBFwKBKAOBAgKECQKEFwKEKAOE
            AwKBBgKBCgKBDwKBGAKBHwKBKQKBOAOBAwKEBgKECgKEDwKEGAKEHwKEKQKEOAOE
            AgKFCQKFFwKFKAOFAgKGCQKGFwKGKAOGAgKICQKIFwKIKAOIAgKSCQKSFwKSKAOS
            AwKFBgKFCgKFDwKFGAKFHwKFKQKFOAOFAwKGBgKGCgKGDwKGGAKGHwKGKQKGOAOG
            AwKIBgKICgKIDwKIGAKIHwKIKQKIOAOIAwKSBgKSCgKSDwKSGAKSHwKSKQKSOAOS
            AQKaFgOaAQKcFgOcAQKgFgOgAQKjFgOjAQKkFgOkAQKpFgOpAQKqFgOqAQKtFgOt
            AgKaCQKaFwKaKAOaAgKcCQKcFwKcKAOcAgKgCQKgFwKgKAOgAgKjCQKjFwKjKAOj
            AwKaBgKaCgKaDwKaGAKaHwKaKQKaOAOaAwKcBgKcCgKcDwKcGAKcHwKcKQKcOAOc
            AwKgBgKgCgKgDwKgGAKgHwKgKQKgOAOgAwKjBgKjCgKjDwKjGAKjHwKjKQKjOAOj
            AgKkCQKkFwKkKAOkAgKpCQKpFwKpKAOpAgKqCQKqFwKqKAOqAgKtCQKtFwKtKAOt
            AwKkBgKkCgKkDwKkGAKkHwKkKQKkOAOkAwKpBgKpCgKpDwKpGAKpHwKpKQKpOAOp
            AwKqBgKqCgKqDwKqGAKqHwKqKQKqOAOqAwKtBgKtCgKtDwKtGAKtHwKtKQKtOAOt
            iQAAigAAjAAAjQAAkAAAkQAAkwAAlgAAnAAAnwAAowAApgAAqwAArgAAtQAAvgAA
            AAOyAAO1AAO5AAO6AAO7AAO9AAO+AAPEAAPGAAPkAAPoAAPplAAAlQAAlwAAmAAA
            AQKyFgOyAQK1FgO1AQK5FgO5AQK6FgO6AQK7FgO7AQK9FgO9AQK+FgO+AQLEFgPE
            AgKyCQKyFwKyKAOyAgK1CQK1FwK1KAO1AgK5CQK5FwK5KAO5AgK6CQK6FwK6KAO6
            AwKyBgKyCgKyDwKyGAKyHwKyKQKyOAOyAwK1BgK1CgK1DwK1GAK1HwK1KQK1OAO1
            AwK5BgK5CgK5DwK5GAK5HwK5KQK5OAO5AwK6BgK6CgK6DwK6GAK6HwK6KQK6OAO6
            AgK7CQK7FwK7KAO7AgK9CQK9FwK9KAO9AgK+CQK+FwK+KAO+AgLECQLEFwLEKAPE
            AwK7BgK7CgK7DwK7GAK7HwK7KQK7OAO7AwK9BgK9CgK9DwK9GAK9HwK9KQK9OAO9
            AwK+BgK+CgK+DwK+GAK+HwK+KQK+OAO+AwLEBgLECgLEDwLEGALEHwLEKQLEOAPE
            AQLGFgPGAQLkFgPkAQLoFgPoAQLpFgPpAAMBAAOHAAOJAAOKAAOLAAOMAAONAAOP
            AgLGCQLGFwLGKAPGAgLkCQLkFwLkKAPkAgLoCQLoFwLoKAPoAgLpCQLpFwLpKAPp
            AwLGBgLGCgLGDwLGGALGHwLGKQLGOAPGAwLkBgLkCgLkDwLkGALkHwLkKQLkOAPk
            AwLoBgLoCgLoDwLoGALoHwLoKQLoOAPoAwLpBgLpCgLpDwLpGALpHwLpKQLpOAPp
            AQIBFgMBAQKHFgOHAQKJFgOJAQKKFgOKAQKLFgOLAQKMFgOMAQKNFgONAQKPFgOP
            AgIBCQIBFwIBKAMBAgKHCQKHFwKHKAOHAgKJCQKJFwKJKAOJAgKKCQKKFwKKKAOK
            AwIBBgIBCgIBDwIBGAIBHwIBKQIBOAMBAwKHBgKHCgKHDwKHGAKHHwKHKQKHOAOH
            AwKJBgKJCgKJDwKJGAKJHwKJKQKJOAOJAwKKBgKKCgKKDwKKGAKKHwKKKQKKOAOK
            AgKLCQKLFwKLKAOLAgKMCQKMFwKMKAOMAgKNCQKNFwKNKAONAgKPCQKPFwKPKAOP
            AwKLBgKLCgKLDwKLGAKLHwKLKQKLOAOLAwKMBgKMCgKMDwKMGAKMHwKMKQKMOAOM
            AwKNBgKNCgKNDwKNGAKNHwKNKQKNOAONAwKPBgKPCgKPDwKPGAKPHwKPKQKPOAOP
            nQAAngAAoAAAoQAApAAApQAApwAAqAAArAAArQAArwAAsQAAtgAAuQAAvwAAzwAA
            AAOTAAOVAAOWAAOXAAOYAAObAAOdAAOeAAOlAAOmAAOoAAOuAAOvAAO0AAO2AAO3
            AQKTFgOTAQKVFgOVAQKWFgOWAQKXFgOXAQKYFgOYAQKbFgObAQKdFgOdAQKeFgOe
            AgKTCQKTFwKTKAOTAgKVCQKVFwKVKAOVAgKWCQKWFwKWKAOWAgKXCQKXFwKXKAOX
            AwKTBgKTCgKTDwKTGAKTHwKTKQKTOAOTAwKVBgKVCgKVDwKVGAKVHwKVKQKVOAOV
            AwKWBgKWCgKWDwKWGAKWHwKWKQKWOAOWAwKXBgKXCgKXDwKXGAKXHwKXKQKXOAOX
            AgKYCQKYFwKYKAOYAgKbCQKbFwKbKAObAgKdCQKdFwKdKAOdAgKeCQKeFwKeKAOe
            AwKYBgKYCgKYDwKYGAKYHwKYKQKYOAOYAwKbBgKbCgKbDwKbGAKbHwKbKQKbOAOb
            AwKdBgKdCgKdDwKdGAKdHwKdKQKdOAOdAwKeBgKeCgKeDwKeGAKeHwKeKQKeOAOe
            AQKlFgOlAQKmFgOmAQKoFgOoAQKuFgOuAQKvFgOvAQK0FgO0AQK2FgO2AQK3FgO3
            AgKlCQKlFwKlKAOlAgKmCQKmFwKmKAOmAgKoCQKoFwKoKAOoAgKuCQKuFwKuKAOu
            AwKlBgKlCgKlDwKlGAKlHwKlKQKlOAOlAwKmBgKmCgKmDwKmGAKmHwKmKQKmOAOm
            AwKoBgKoCgKoDwKoGAKoHwKoKQKoOAOoAwKuBgKuCgKuDwKuGAKuHwKuKQKuOAOu
            AgKvCQKvFwKvKAOvAgK0CQK0FwK0KAO0AgK2CQK2FwK2KAO2AgK3CQK3FwK3KAO3
            AwKvBgKvCgKvDwKvGAKvHwKvKQKvOAOvAwK0BgK0CgK0DwK0GAK0HwK0KQK0OAO0
            AwK2BgK2CgK2DwK2GAK2HwK2KQK2OAO2AwK3BgK3CgK3DwK3GAK3HwK3KQK3OAO3
            AAO8AAO/AAPFAAPnAAPvsAAAsgAAswAAtwAAuAAAugAAuwAAwAAAxwAA0AAA3wAA
            AQK8FgO8AQK/FgO/AQLFFgPFAQLnFgPnAQLvFgPvAAMJAAOOAAOQAAORAAOUAAOf
            AgK8CQK8FwK8KAO8AgK/CQK/FwK/KAO/AgLFCQLFFwLFKAPFAgLnCQLnFwLnKAPn
            AwK8BgK8CgK8DwK8GAK8HwK8KQK8OAO8AwK/BgK/CgK/DwK/GAK/HwK/KQK/OAO/
            AwLFBgLFCgLFDwLFGALFHwLFKQLFOAPFAwLnBgLnCgLnDwLnGALnHwLnKQLnOAPn
            AgLvCQLvFwLvKAPvAQIJFgMJAQKOFgOOAQKQFgOQAQKRFgORAQKUFgOUAQKfFgOf
            AwLvBgLvCgLvDwLvGALvHwLvKQLvOAPvAgIJCQIJFwIJKAMJAgKOCQKOFwKOKAOO
            AwIJBgIJCgIJDwIJGAIJHwIJKQIJOAMJAwKOBgKOCgKODwKOGAKOHwKOKQKOOAOO
            AgKQCQKQFwKQKAOQAgKRCQKRFwKRKAORAgKUCQKUFwKUKAOUAgKfCQKfFwKfKAOf
            AwKQBgKQCgKQDwKQGAKQHwKQKQKQOAOQAwKRBgKRCgKRDwKRGAKRHwKRKQKROAOR
            AwKUBgKUCgKUDwKUGAKUHwKUKQKUOAOUAwKfBgKfCgKfDwKfGAKfHwKfKQKfOAOf
            AAOrAAPOAAPXAAPhAAPsAAPtvAAAvQAAwQAAxAAAyAAAywAA0QAA2AAA4AAA7gAA
            AQKrFgOrAQLOFgPOAQLXFgPXAQLhFgPhAQLsFgPsAQLtFgPtAAPHAAPPAAPqAAPr
            AgKrCQKrFwKrKAOrAgLOCQLOFwLOKAPOAgLXCQLXFwLXKAPXAgLhCQLhFwLhKAPh
            AwKrBgKrCgKrDwKrGAKrHwKrKQKrOAOrAwLOBgLOCgLODwLOGALOHwLOKQLOOAPO
            AwLXBgLXCgLXDwLXGALXHwLXKQLXOAPXAwLhBgLhCgLhDwLhGALhHwLhKQLhOAPh
            AgLsCQLsFwLsKAPsAgLtCQLtFwLtKAPtAQLHFgPHAQLPFgPPAQLqFgPqAQLrFgPr
            AwLsBgLsCgLsDwLsGALsHwLsKQLsOAPsAwLtBgLtCgLtDwLtGALtHwLtKQLtOAPt
            AgLHCQLHFwLHKAPHAgLPCQLPFwLPKAPPAgLqCQLqFwLqKAPqAgLrCQLrFwLrKAPr
            AwLHBgLHCgLHDwLHGALHHwLHKQLHOAPHAwLPBgLPCgLPDwLPGALPHwLPKQLPOAPP
            AwLqBgLqCgLqDwLqGALqHwLqKQLqOAPqAwLrBgLrCgLrDwLrGALrHwLrKQLrOAPr
            wgAAwwAAxQAAxgAAyQAAygAAzAAAzQAA0gAA1QAA2QAA3AAA4QAA5wAA7wAA9gAA
            AAPAAAPBAAPIAAPJAAPKAAPNAAPSAAPVAAPaAAPbAAPuAAPwAAPyAAPzAAP/zgAA
            AQLAFgPAAQLBFgPBAQLIFgPIAQLJFgPJAQLKFgPKAQLNFgPNAQLSFgPSAQLVFgPV
            AgLACQLAFwLAKAPAAgLBCQLBFwLBKAPBAgLICQLIFwLIKAPIAgLJCQLJFwLJKAPJ
            AwLABgLACgLADwLAGALAHwLAKQLAOAPAAwLBBgLBCgLBDwLBGALBHwLBKQLBOAPB
            AwLIBgLICgLIDwLIGALIHwLIKQLIOAPIAwLJBgLJCgLJDwLJGALJHwLJKQLJOAPJ
            AgLKCQLKFwLKKAPKAgLNCQLNFwLNKAPNAgLSCQLSFwLSKAPSAgLVCQLVFwLVKAPV
            AwLKBgLKCgLKDwLKGALKHwLKKQLKOAPKAwLNBgLNCgLNDwLNGALNHwLNKQLNOAPN
            AwLSBgLSCgLSDwLSGALSHwLSKQLSOAPSAwLVBgLVCgLVDwLVGALVHwLVKQLVOAPV
            AQLaFgPaAQLbFgPbAQLuFgPuAQLwFgPwAQLyFgPyAQLzFgPzAQL/FgP/AAPLAAPM
            AgLaCQLaFwLaKAPaAgLbCQLbFwLbKAPbAgLuCQLuFwLuKAPuAgLwCQLwFwLwKAPw
            AwLaBgLaCgLaDwLaGALaHwLaKQLaOAPaAwLbBgLbCgLbDwLbGALbHwLbKQLbOAPb
            AwLuBgLuCgLuDwLuGALuHwLuKQLuOAPuAwLwBgLwCgLwDwLwGALwHwLwKQLwOAPw
            AgLyCQLyFwLyKAPyAgLzCQLzFwLzKAPzAgL/CQL/FwL/KAP/AQLLFgPLAQLMFgPM
            AwLyBgLyCgLyDwLyGALyHwLyKQLyOAPyAwLzBgLzCgLzDwLzGALzHwLzKQLzOAPz
            AwL/BgL/CgL/DwL/GAL/HwL/KQL/OAP/AgLLCQLLFwLLKAPLAgLMCQLMFwLMKAPM
            AwLLBgLLCgLLDwLLGALLHwLLKQLLOAPLAwLMBgLMCgLMDwLMGALMHwLMKQLMOAPM
            0wAA1AAA1gAA1wAA2gAA2wAA3QAA3gAA4gAA5AAA6AAA6wAA8AAA8wAA9wAA+gAA
            AAPTAAPUAAPWAAPdAAPeAAPfAAPxAAP0AAP1AAP2AAP3AAP4AAP6AAP7AAP8AAP9
            AQLTFgPTAQLUFgPUAQLWFgPWAQLdFgPdAQLeFgPeAQLfFgPfAQLxFgPxAQL0FgP0
            AgLTCQLTFwLTKAPTAgLUCQLUFwLUKAPUAgLWCQLWFwLWKAPWAgLdCQLdFwLdKAPd
            AwLTBgLTCgLTDwLTGALTHwLTKQLTOAPTAwLUBgLUCgLUDwLUGALUHwLUKQLUOAPU
            AwLWBgLWCgLWDwLWGALWHwLWKQLWOAPWAwLdBgLdCgLdDwLdGALdHwLdKQLdOAPd
            AgLeCQLeFwLeKAPeAgLfCQLfFwLfKAPfAgLxCQLxFwLxKAPxAgL0CQL0FwL0KAP0
            AwLeBgLeCgLeDwLeGALeHwLeKQLeOAPeAwLfBgLfCgLfDwLfGALfHwLfKQLfOAPf
            AwLxBgLxCgLxDwLxGALxHwLxKQLxOAPxAwL0BgL0CgL0DwL0GAL0HwL0KQL0OAP0
            AQL1FgP1AQL2FgP2AQL3FgP3AQL4FgP4AQL6FgP6AQL7FgP7AQL8FgP8AQL9FgP9
            AgL1CQL1FwL1KAP1AgL2CQL2FwL2KAP2AgL3CQL3FwL3KAP3AgL4CQL4FwL4KAP4
            AwL1BgL1CgL1DwL1GAL1HwL1KQL1OAP1AwL2BgL2CgL2DwL2GAL2HwL2KQL2OAP2
            AwL3BgL3CgL3DwL3GAL3HwL3KQL3OAP3AwL4BgL4CgL4DwL4GAL4HwL4KQL4OAP4
            AgL6CQL6FwL6KAP6AgL7CQL7FwL7KAP7AgL8CQL8FwL8KAP8AgL9CQL9FwL9KAP9
            AwL6BgL6CgL6DwL6GAL6HwL6KQL6OAP6AwL7BgL7CgL7DwL7GAL7HwL7KQL7OAP7
            AwL8BgL8CgL8DwL8GAL8HwL8KQL8OAP8AwL9BgL9CgL9DwL9GAL9HwL9KQL9OAP9
            AAP+4wAA5QAA5gAA6QAA6gAA7AAA7QAA8QAA8gAA9AAA9QAA+AAA+QAA+wAA/AAA
            AQL+FgP+AAMCAAMDAAMEAAMFAAMGAAMHAAMIAAMLAAMMAAMOAAMPAAMQAAMRAAMS
            AgL+CQL+FwL+KAP+AQICFgMCAQIDFgMDAQIEFgMEAQIFFgMFAQIGFgMGAQIHFgMH
            AwL+BgL+CgL+DwL+GAL+HwL+KQL+OAP+AgICCQICFwICKAMCAgIDCQIDFwIDKAMD
            AwICBgICCgICDwICGAICHwICKQICOAMCAwIDBgIDCgIDDwIDGAIDHwIDKQIDOAMD
            AgIECQIEFwIEKAMEAgIFCQIFFwIFKAMFAgIGCQIGFwIGKAMGAgIHCQIHFwIHKAMH
            AwIEBgIECgIEDwIEGAIEHwIEKQIEOAMEAwIFBgIFCgIFDwIFGAIFHwIFKQIFOAMF
            AwIGBgIGCgIGDwIGGAIGHwIGKQIGOAMGAwIHBgIHCgIHDwIHGAIHHwIHKQIHOAMH
            AQIIFgMIAQILFgMLAQIMFgMMAQIOFgMOAQIPFgMPAQIQFgMQAQIRFgMRAQISFgMS
            AgIICQIIFwIIKAMIAgILCQILFwILKAMLAgIMCQIMFwIMKAMMAgIOCQIOFwIOKAMO
            AwIIBgIICgIIDwIIGAIIHwIIKQIIOAMIAwILBgILCgILDwILGAILHwILKQILOAML
            AwIMBgIMCgIMDwIMGAIMHwIMKQIMOAMMAwIOBgIOCgIODwIOGAIOHwIOKQIOOAMO
            AgIPCQIPFwIPKAMPAgIQCQIQFwIQKAMQAgIRCQIRFwIRKAMRAgISCQISFwISKAMS
            AwIPBgIPCgIPDwIPGAIPHwIPKQIPOAMPAwIQBgIQCgIQDwIQGAIQHwIQKQIQOAMQ
            AwIRBgIRCgIRDwIRGAIRHwIRKQIROAMRAwISBgISCgISDwISGAISHwISKQISOAMS
            AAMTAAMUAAMVAAMXAAMYAAMZAAMaAAMbAAMcAAMdAAMeAAMfAAN/AAPcAAP5/QAA
            AQITFgMTAQIUFgMUAQIVFgMVAQIXFgMXAQIYFgMYAQIZFgMZAQIaFgMaAQIbFgMb
            AgITCQITFwITKAMTAgIUCQIUFwIUKAMUAgIVCQIVFwIVKAMVAgIXCQIXFwIXKAMX
            AwITBgITCgITDwITGAITHwITKQITOAMTAwIUBgIUCgIUDwIUGAIUHwIUKQIUOAMU
            AwIVBgIVCgIVDwIVGAIVHwIVKQIVOAMVAwIXBgIXCgIXDwIXGAIXHwIXKQIXOAMX
            AgIYCQIYFwIYKAMYAgIZCQIZFwIZKAMZAgIaCQIaFwIaKAMaAgIbCQIbFwIbKAMb
            AwIYBgIYCgIYDwIYGAIYHwIYKQIYOAMYAwIZBgIZCgIZDwIZGAIZHwIZKQIZOAMZ
            AwIaBgIaCgIaDwIaGAIaHwIaKQIaOAMaAwIbBgIbCgIbDwIbGAIbHwIbKQIbOAMb
            AQIcFgMcAQIdFgMdAQIeFgMeAQIfFgMfAQJ/FgN/AQLcFgPcAQL5FgP5/gAA/wAA
            AgIcCQIcFwIcKAMcAgIdCQIdFwIdKAMdAgIeCQIeFwIeKAMeAgIfCQIfFwIfKAMf
            AwIcBgIcCgIcDwIcGAIcHwIcKQIcOAMcAwIdBgIdCgIdDwIdGAIdHwIdKQIdOAMd
            AwIeBgIeCgIeDwIeGAIeHwIeKQIeOAMeAwIfBgIfCgIfDwIfGAIfHwIfKQIfOAMf
            AgJ/CQJ/FwJ/KAN/AgLcCQLcFwLcKAPcAgL5CQL5FwL5KAP5AAMKAAMNAAMWAAQA
            AwJ/BgJ/CgJ/DwJ/GAJ/HwJ/KQJ/OAN/AwLcBgLcCgLcDwLcGALcHwLcKQLcOAPc
            AwL5BgL5CgL5DwL5GAL5HwL5KQL5OAP5AQIKFgMKAQINFgMNAQIWFgMWAAQAAAQA
            AgIKCQIKFwIKKAMKAgINCQINFwINKAMNAgIWCQIWFwIWKAMWAAQAAAQAAAQAAAQA
            AwIKBgIKCgIKDwIKGAIKHwIKKQIKOAMKAwINBgINCgINDwINGAINHwINKQINOAMN
            AwIWBgIWCgIWDwIWGAIWHwIWKQIWOAMWAAQAAAQAAAQAAAQAAAQAAAQAAAQAAAQA
            """
        return base64_table_bytes.withUTF8Buffer { buf in
            // ignore newlines in the input
            guard let result = base64DecodeBytes(buf, ignoreUnknownCharacters: true) else {
                fatalError("Failed to decode huffman decoder table from base-64 encoding")
            }
            return result.withUnsafeBytes { ptr in
                assert(ptr.count % 3 == 0)
                let dptr = ptr.baseAddress!.assumingMemoryBound(to: HuffmanDecodeEntry.self)
                let dbuf = UnsafeBufferPointer(start: dptr, count: ptr.count / 3)
                return Array(dbuf)
            }
        }
    }()
}
