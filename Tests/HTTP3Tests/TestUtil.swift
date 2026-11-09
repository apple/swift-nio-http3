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

@_spi(PackageInternal) @testable public import HTTP3
@_spi(PackageInternal) import QPACK

@available(anyAppleOS 27, *)
extension HTTP3PushID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}

@available(anyAppleOS 27, *)
extension HTTP3GoawayID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}

extension ByteBuffer {
    /// Write `frame`. `writeHTTP3PartialFrame(_:)` doesn't write HEADERS and PUSH_PROMISE frames, so this writes
    /// their field sections line by line.
    @available(anyAppleOS 27, *)
    mutating func writeTestFrame(_ frame: HTTP3PartialFrame, preferHuffmanEncoding: Bool = false) {
        switch frame {
        case .headers(let payload):
            self.writeEncodedInteger(HTTP3FrameType.headers.rawValue, strategy: .quic)
            self.writeLengthPrefixed(strategy: .quic) { tempBuffer in
                tempBuffer.writeFieldSection(payload.fieldSection, preferHuffmanEncoding: preferHuffmanEncoding)
            }
        case .pushPromise(let payload):
            self.writeEncodedInteger(HTTP3FrameType.pushPromise.rawValue, strategy: .quic)
            self.writeLengthPrefixed(strategy: .quic) { tempBuffer in
                tempBuffer.writeEncodedInteger(payload.pushID.rawValue, strategy: .quic)
                    + tempBuffer.writeFieldSection(payload.fieldSection, preferHuffmanEncoding: preferHuffmanEncoding)
            }
        case .data, .cancelPush, .settings, .goaway, .maxPushID:
            self.writeHTTP3PartialFrame(frame)
        }
    }

    /// Write `fieldSection` line by line.
    /// - Returns: The number of bytes written.
    @available(anyAppleOS 27, *)
    @discardableResult
    mutating func writeFieldSection(_ fieldSection: FieldSection, preferHuffmanEncoding: Bool = false) -> Int {
        var maxLength = QPACKEncodedLength.fieldSectionPrefix(fieldSection.prefix)
        for line in fieldSection.lines {
            maxLength += QPACKEncodedLength.maxFieldLine(line)
        }
        let start = self.writerIndex
        self.writeWithOutputRawSpan(minimumWritableBytes: maxLength) { output in
            output.appendFieldSectionPrefix(fieldSection.prefix)
            for line in fieldSection.lines {
                output.appendFieldLine(line, preferHuffmanEncoding: preferHuffmanEncoding)
            }
        }
        return self.writerIndex - start
    }
}
