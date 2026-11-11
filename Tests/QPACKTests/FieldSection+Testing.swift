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

// Field sections travel as their bytes. The tests describe them line by line as a `FieldSection`, which they can
// compare, and turn into the bytes the decoder reads.

/// A field section as per RFC 9204 § 4.5.
@available(anyAppleOS 27, *)
struct FieldSection: Equatable {
    var prefix: EncodedFieldSectionPrefix
    var lines: [FieldLine]

    init(prefix: EncodedFieldSectionPrefix, lines: [FieldLine]) {
        self.prefix = prefix
        self.lines = lines
    }

    /// Reads the field section which takes up the whole of `buffer`.
    init(readingAll buffer: ByteBuffer, sourceLocation: SourceLocation = #_sourceLocation) {
        var buffer = buffer
        self.prefix = try! buffer.readFieldSectionPrefix()!
        var lines = [FieldLine]()
        while let line = try! buffer.readFieldLine() {
            lines.append(line)
        }
        self.lines = lines
        #expect(buffer.readableBytes == 0, sourceLocation: sourceLocation)
    }

    /// The section's bytes, written into exactly the room the prefix and the lines can take.
    func bytes(preferHuffmanEncoding: Bool = false) -> ByteBuffer {
        let maxLength = QPACKEncodedLength.fieldSectionPrefix(self.prefix) + self.lines.maxEncodedLength
        let (buffer, _) = encodeWithExactRoom(maxLength) { output in
            output.appendFieldSectionPrefix(self.prefix)
            self.lines.append(to: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        }
        return buffer
    }
}

extension ByteBuffer {
    /// The bytes of `fieldLines`, without a prefix, written into exactly the room they can take.
    @available(anyAppleOS 27, *)
    init(fieldLines: [FieldLine], preferHuffmanEncoding: Bool = false) {
        (self, _) = encodeWithExactRoom(fieldLines.maxEncodedLength) { output in
            fieldLines.append(to: &output, preferHuffmanEncoding: preferHuffmanEncoding)
        }
    }
}

@available(anyAppleOS 27, *)
extension [FieldLine] {
    fileprivate var maxEncodedLength: Int {
        self.reduce(0) { $0 + QPACKEncodedLength.maxFieldLine($1) }
    }

    fileprivate func append(to output: inout OutputRawSpan, preferHuffmanEncoding: Bool) {
        for line in self {
            output.appendFieldLine(line, preferHuffmanEncoding: preferHuffmanEncoding)
        }
    }
}
