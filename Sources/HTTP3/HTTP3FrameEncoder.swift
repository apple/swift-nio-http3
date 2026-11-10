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

extension ByteBuffer {
    /// Write a single ``HTTP3PartialFrame`` into the ByteBuffer, and move the writer index to just after the frame.
    ///
    /// The `QPACKCoder` writes HEADERS frames, through ``writeHeadersFrame(maxPayloadLength:encodePayload:)``, and
    /// PUSH_PROMISE frames are never written. It is a fatal error to call this function with either.
    /// See also: ``HTTP3FrameDecoder``.
    /// - Parameter frame: The frame to be written to the `ByteBuffer`.
    @available(anyAppleOS 27, *)
    mutating func writeHTTP3PartialFrame(_ frame: HTTP3PartialFrame) {
        switch frame {
        case .data(let payload):
            self.writeEncodedInteger(HTTP3FrameType.data.rawValue, strategy: .quic)
            self.writeLengthPrefixedBuffer(payload.payload, strategy: .quic)
        case .headers:
            fatalError("HEADERS frames are written by the QPACKCoder")
        case .cancelPush(let payload):
            self.writeEncodedInteger(HTTP3FrameType.cancelPush.rawValue, strategy: .quic)
            self.writeLengthPrefixedQUICEncodedInteger(payload.pushID.rawValue)
        case .settings(let payload):
            self.writeEncodedInteger(HTTP3FrameType.settings.rawValue, strategy: .quic)
            self.writeLengthPrefixed(strategy: .quic(requiredBytesHint: .two)) { tempBuffer in
                tempBuffer.writeHTTP3Settings(payload.settings)
            }
        case .pushPromise:
            fatalError("Writing PUSH_PROMISE frames is not supported")
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
    /// Write a HEADERS frame, whose payload `encodePayload` appends.
    ///
    /// - Parameters:
    ///   - maxPayloadLength: The largest number of bytes `encodePayload` appends. The frame's length takes as many
    ///     bytes as this needs, so that the payload never has to be moved once it's written.
    ///   - encodePayload: Appends the QPACK encoded field section to the span, which has room for
    ///     `maxPayloadLength` bytes.
    @available(anyAppleOS 27, *)
    mutating func writeHeadersFrame(maxPayloadLength: Int, encodePayload: (inout OutputRawSpan) -> Void) {
        self.writeEncodedInteger(HTTP3FrameType.headers.rawValue, strategy: .quic)
        // Safe to unwrap: `bytesNeededForInteger` only returns 1, 2, 4 or 8.
        let lengthLength = ByteBuffer.QUICBinaryEncodingStrategy.IntegerLength(
            rawValue: ByteBuffer.QUICBinaryEncodingStrategy.bytesNeededForInteger(maxPayloadLength)
        )!
        self.writeLengthPrefixed(strategy: .quic(requiredBytesHint: lengthLength)) { buffer in
            let start = buffer.writerIndex
            buffer.writeWithOutputRawSpan(minimumWritableBytes: maxPayloadLength, initializingWith: encodePayload)
            let payloadLength = buffer.writerIndex &- start
            // A longer payload would need a longer length, and be moved to make room for it.
            assert(payloadLength <= maxPayloadLength, "The payload is longer than its maximum length")
            return payloadLength
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
}
