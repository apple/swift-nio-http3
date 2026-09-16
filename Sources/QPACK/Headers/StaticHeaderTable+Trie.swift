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

extension StaticHeaderTable {
    /// Resolves `canonicalName` to the static table indices carrying that name, or an empty
    /// group if the static table doesn't carry it.
    ///
    /// A trie over the UTF-8 bytes of the canonical (lowercase) name: it dispatches on the
    /// length first, then on whichever byte positions discriminate the remaining candidates,
    /// and finally confirms with a single whole-string comparison. Each dispatch is a jump
    /// table, so a lookup costs a handful of loads instead of hashing the whole name.
    ///
    /// `utf8` must be `canonicalName`'s UTF-8 bytes; call `entryGroup(for:)` instead.
    static func entryGroup(canonicalName: String, utf8: UnsafeBufferPointer<UInt8>) -> StaticEntryGroup {
        switch utf8.count {
        case 3:
            canonicalName == "age" ? StaticEntryGroup(2, 3) : .none
        case 4:
            switch utf8[position: 0] {
            case UInt8(ascii: "d"):
                canonicalName == "date" ? StaticEntryGroup(6, 7) : .none
            case UInt8(ascii: "e"):
                canonicalName == "etag" ? StaticEntryGroup(7, 8) : .none
            case UInt8(ascii: "l"):
                canonicalName == "link" ? StaticEntryGroup(11, 12) : .none
            case UInt8(ascii: "v"):
                canonicalName == "vary" ? StaticEntryGroup(59, 61) : .none
            default:
                .none
            }
        case 5:
            switch utf8[position: 0] {
            case UInt8(ascii: ":"):
                canonicalName == ":path" ? StaticEntryGroup(1, 2) : .none
            case UInt8(ascii: "r"):
                canonicalName == "range" ? StaticEntryGroup(55, 56) : .none
            default:
                .none
            }
        case 6:
            switch utf8[position: 0] {
            case UInt8(ascii: "a"):
                canonicalName == "accept" ? StaticEntryGroup(29, 31) : .none
            case UInt8(ascii: "c"):
                canonicalName == "cookie" ? StaticEntryGroup(5, 6) : .none
            case UInt8(ascii: "o"):
                canonicalName == "origin" ? StaticEntryGroup(90, 91) : .none
            case UInt8(ascii: "s"):
                canonicalName == "server" ? StaticEntryGroup(92, 93) : .none
            default:
                .none
            }
        case 7:
            switch utf8[position: 3] {
            case UInt8(ascii: "-"):
                canonicalName == "alt-svc" ? StaticEntryGroup(83, 84) : .none
            case UInt8(ascii: "a"):
                canonicalName == ":status" ? StaticEntryGroup(24, 29, 63, 72) : .none
            case UInt8(ascii: "e"):
                canonicalName == "referer" ? StaticEntryGroup(13, 14) : .none
            case UInt8(ascii: "h"):
                canonicalName == ":scheme" ? StaticEntryGroup(22, 24) : .none
            case UInt8(ascii: "p"):
                canonicalName == "purpose" ? StaticEntryGroup(91, 92) : .none
            case UInt8(ascii: "t"):
                canonicalName == ":method" ? StaticEntryGroup(15, 22) : .none
            default:
                .none
            }
        case 8:
            switch utf8[position: 0] {
            case UInt8(ascii: "i"):
                canonicalName == "if-range" ? StaticEntryGroup(89, 90) : .none
            case UInt8(ascii: "l"):
                canonicalName == "location" ? StaticEntryGroup(12, 13) : .none
            default:
                .none
            }
        case 9:
            switch utf8[position: 0] {
            case UInt8(ascii: "e"):
                canonicalName == "expect-ct" ? StaticEntryGroup(87, 88) : .none
            case UInt8(ascii: "f"):
                canonicalName == "forwarded" ? StaticEntryGroup(88, 89) : .none
            default:
                .none
            }
        case 10:
            switch utf8[position: 0] {
            case UInt8(ascii: ":"):
                canonicalName == ":authority" ? StaticEntryGroup(0, 1) : .none
            case UInt8(ascii: "e"):
                canonicalName == "early-data" ? StaticEntryGroup(86, 87) : .none
            case UInt8(ascii: "s"):
                canonicalName == "set-cookie" ? StaticEntryGroup(14, 15) : .none
            case UInt8(ascii: "u"):
                canonicalName == "user-agent" ? StaticEntryGroup(95, 96) : .none
            default:
                .none
            }
        case 12:
            canonicalName == "content-type" ? StaticEntryGroup(44, 55) : .none
        case 13:
            switch utf8[position: 5] {
            case UInt8(ascii: "-"):
                canonicalName == "cache-control" ? StaticEntryGroup(36, 42) : .none
            case UInt8(ascii: "m"):
                canonicalName == "last-modified" ? StaticEntryGroup(10, 11) : .none
            case UInt8(ascii: "n"):
                canonicalName == "if-none-match" ? StaticEntryGroup(9, 10) : .none
            case UInt8(ascii: "r"):
                canonicalName == "authorization" ? StaticEntryGroup(84, 85) : .none
            case UInt8(ascii: "t"):
                canonicalName == "accept-ranges" ? StaticEntryGroup(32, 33) : .none
            default:
                .none
            }
        case 14:
            canonicalName == "content-length" ? StaticEntryGroup(4, 5) : .none
        case 15:
            switch utf8[position: 7] {
            case UInt8(ascii: "-"):
                canonicalName == "x-frame-options" ? StaticEntryGroup(97, 99) : .none
            case UInt8(ascii: "e"):
                canonicalName == "accept-encoding" ? StaticEntryGroup(31, 32) : .none
            case UInt8(ascii: "l"):
                canonicalName == "accept-language" ? StaticEntryGroup(72, 73) : .none
            case UInt8(ascii: "r"):
                canonicalName == "x-forwarded-for" ? StaticEntryGroup(96, 97) : .none
            default:
                .none
            }
        case 16:
            switch utf8[position: 0] {
            case UInt8(ascii: "c"):
                canonicalName == "content-encoding" ? StaticEntryGroup(42, 44) : .none
            case UInt8(ascii: "x"):
                canonicalName == "x-xss-protection" ? StaticEntryGroup(62, 63) : .none
            default:
                .none
            }
        case 17:
            canonicalName == "if-modified-since" ? StaticEntryGroup(8, 9) : .none
        case 19:
            switch utf8[position: 0] {
            case UInt8(ascii: "c"):
                canonicalName == "content-disposition" ? StaticEntryGroup(3, 4) : .none
            case UInt8(ascii: "t"):
                canonicalName == "timing-allow-origin" ? StaticEntryGroup(93, 94) : .none
            default:
                .none
            }
        case 22:
            canonicalName == "x-content-type-options" ? StaticEntryGroup(61, 62) : .none
        case 23:
            canonicalName == "content-security-policy" ? StaticEntryGroup(85, 86) : .none
        case 25:
            switch utf8[position: 0] {
            case UInt8(ascii: "s"):
                canonicalName == "strict-transport-security" ? StaticEntryGroup(56, 59) : .none
            case UInt8(ascii: "u"):
                canonicalName == "upgrade-insecure-requests" ? StaticEntryGroup(94, 95) : .none
            default:
                .none
            }
        case 27:
            canonicalName == "access-control-allow-origin" ? StaticEntryGroup(35, 36) : .none
        case 28:
            switch utf8[position: 21] {
            case UInt8(ascii: "h"):
                canonicalName == "access-control-allow-headers" ? StaticEntryGroup(33, 35, 75, 76) : .none
            case UInt8(ascii: "m"):
                canonicalName == "access-control-allow-methods" ? StaticEntryGroup(76, 79) : .none
            default:
                .none
            }
        case 29:
            switch utf8[position: 15] {
            case UInt8(ascii: "e"):
                canonicalName == "access-control-expose-headers" ? StaticEntryGroup(79, 80) : .none
            case UInt8(ascii: "r"):
                canonicalName == "access-control-request-method" ? StaticEntryGroup(81, 83) : .none
            default:
                .none
            }
        case 30:
            canonicalName == "access-control-request-headers" ? StaticEntryGroup(80, 81) : .none
        case 32:
            canonicalName == "access-control-allow-credentials" ? StaticEntryGroup(73, 75) : .none
        default:
            .none
        }
    }
}
