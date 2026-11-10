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

// The `RawSpan` readers are handed whatever bytes have arrived so far. When those end before the representation
// does, they have to return nil, and never read past the end of the span.

/// The bytes `body` appends.
@available(anyAppleOS 27, *)
func encodedBytes(_ body: (inout OutputRawSpan) -> Void) -> [UInt8] {
    var buffer = ByteBuffer()
    buffer.writeWithOutputRawSpan(minimumWritableBytes: 1024) { body(&$0) }
    return Array(buffer.readableBytesView)
}

/// Reads `encoded` cut short at every length, both from the start of the span and behind bytes which have to be
/// skipped. The whole of `encoded` has to read back as `expected`, from exactly its bytes, and every shorter span as
/// nil.
@available(anyAppleOS 27, *)
func expectEveryTruncationIsIncomplete<Value>(
    _ encoded: [UInt8],
    decodingTo expected: Value,
    sourceLocation: SourceLocation = #_sourceLocation,
    read: (RawSpan, Int) throws(IntegerReadingError) -> Decoded<Value>?
) throws {
    for leadingBytes in [0, 3] {
        // The leading bytes have every bit set, so that reading any of them goes wrong.
        let bytes = [UInt8](repeating: 0xff, count: leadingBytes) + encoded
        let span = bytes.span.bytes

        let whole = try read(span, leadingBytes)
        #expect(
            whole == Decoded(value: expected, bytesRead: encoded.count),
            "behind \(leadingBytes)",
            sourceLocation: sourceLocation
        )

        for byteCount in leadingBytes..<bytes.count {
            let truncated = try read(span.extracting(0..<byteCount), leadingBytes)
            #expect(
                truncated == nil,
                "\(expected): \(byteCount - leadingBytes) of \(encoded.count) bytes, behind \(leadingBytes)",
                sourceLocation: sourceLocation
            )
        }
    }
}

/// Offsets at which there is nothing to read in a span of `byteCount` bytes.
func offsetsOutsideASpan(of byteCount: Int) -> [Int] {
    [-1, byteCount, byteCount + 1, .max]
}
