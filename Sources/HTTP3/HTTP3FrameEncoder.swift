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
@_spi(PackageInternal) import QPACK

import struct NIOCore.ByteBuffer

extension ByteBuffer {
    /// Write a single ``HTTP3PartialFrame`` into the ByteBuffer, and move the writer index to just after the frame.
    ///
    /// As a reminder, if you want to encode a ``HTTP3Frame``, you must first put it through a QPACK encoder to get a ``HTTP3PartialFrame`` before you can use this function.
    /// This function is stateless, because the frame has already been through QPACK, it just needs to be written.
    /// See also: ``HTTP3FrameDecoder``.
    /// - Parameters:
    /// - frame: The frame to be written to the `ByteBuffer`.
    /// - preferHuffmanEncoding: If true, huffman coding will be preferred where applicable, e.g. header field sections. It will not be used if doing so would use more space than not.
    mutating func writeHTTP3PartialFrame(_ frame: HTTP3PartialFrame, preferHuffmanEncoding: Bool) {
        switch frame {
        case .data(let payload):
            self.writeEncodedInteger(HTTP3FrameType.data.rawValue, strategy: .quic)
            self.writeLengthPrefixedBuffer(payload.payload, strategy: .quic)
        case .headers(let payload):
            self.writeEncodedInteger(HTTP3FrameType.headers.rawValue, strategy: .quic)
            self.writeLengthPrefixed(strategy: .quic) { tempBuffer in
                tempBuffer.writeFieldSection(payload.fieldSection, preferHuffmanEncoding: preferHuffmanEncoding)
            }
        case .cancelPush(let payload):
            self.writeEncodedInteger(HTTP3FrameType.cancelPush.rawValue, strategy: .quic)
            self.writeLengthPrefixedQUICEncodedInteger(payload.pushID.rawValue)
        case .settings(let payload):
            self.writeEncodedInteger(HTTP3FrameType.settings.rawValue, strategy: .quic)
            self.writeLengthPrefixed(strategy: .quic(requiredBytesHint: .two)) { tempBuffer in
                tempBuffer.writeHTTP3Settings(payload.settings)
            }
        case .pushPromise(let payload):
            self.writeEncodedInteger(HTTP3FrameType.pushPromise.rawValue, strategy: .quic)
            self.writeLengthPrefixed(strategy: .quic) { tempBuffer in
                var bytesWritten = 0
                bytesWritten += tempBuffer.writeEncodedInteger(payload.pushID.rawValue, strategy: .quic)
                bytesWritten += tempBuffer.writeFieldSection(
                    payload.fieldSection,
                    preferHuffmanEncoding: preferHuffmanEncoding
                )
                return bytesWritten
            }
        case .goaway(let payload):
            self.writeEncodedInteger(HTTP3FrameType.goaway.rawValue, strategy: .quic)
            self.writeLengthPrefixedQUICEncodedInteger(payload.id.rawValue)
        case .maxPushID(let payload):
            self.writeEncodedInteger(HTTP3FrameType.maxPushID.rawValue, strategy: .quic)
            self.writeLengthPrefixedQUICEncodedInteger(payload.id.rawValue)
        }
    }
}

extension ByteBuffer {
    /// Write `value` as a quic encoded integer, prefixed with the number of bytes needed to write `value`, also as a quic-encoded integer.
    ///
    /// E.g. if value is 100:
    /// 100 needs 2 bytes to be written as quic encoded integer.
    /// So we first write `2` encoded with quic, followed by `100` encoded with quic (3 bytes total).
    ///
    /// Value will need either 1, 2, 4 or 8 bytes, and then the length will add one more byte.
    /// So the total bytes written is [bytes required to write value] + 1.
    fileprivate mutating func writeLengthPrefixedQUICEncodedInteger(_ value: some FixedWidthInteger) {
        self.writeEncodedInteger(ByteBuffer.QUICBinaryEncodingStrategy.bytesNeededForInteger(value), strategy: .quic)
        self.writeEncodedInteger(value, strategy: .quic)
    }

    /// Write a field section
    /// - Returns: The number of bytes written
    fileprivate mutating func writeFieldSection(_ fieldSection: FieldSection, preferHuffmanEncoding: Bool) -> Int {
        var bytesWritten = 0
        bytesWritten += self.writeFieldSectionPrefix(fieldSection.prefix)
        for line in fieldSection.lines {
            bytesWritten += self.writeFieldLine(line, preferHuffmanEncoding: preferHuffmanEncoding)
        }
        return bytesWritten
    }
}
