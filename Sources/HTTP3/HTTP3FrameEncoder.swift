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
            let payloadLength = payload.payload.readableBytes
            self.writeWithOutputRawSpan(
                minimumWritableBytes: HTTP3EncodedLength.dataFrameHeader(payloadLength: payloadLength)
            ) {
                $0.appendHTTP3DataFrameHeader(payloadLength: payloadLength)
            }
            self.writeImmutableBuffer(payload.payload)
        case .headers:
            fatalError("HEADERS frames are written by the QPACKCoder")
        case .cancelPush(let payload):
            self.writeWithOutputRawSpan(minimumWritableBytes: HTTP3EncodedLength.cancelPushFrame(payload.pushID)) {
                $0.appendHTTP3CancelPushFrame(payload.pushID)
            }
        case .settings(let payload):
            self.writeWithOutputRawSpan(minimumWritableBytes: HTTP3EncodedLength.settingsFrame(payload.settings)) {
                $0.appendHTTP3SettingsFrame(payload.settings)
            }
        case .pushPromise:
            fatalError("Writing PUSH_PROMISE frames is not supported")
        case .goaway(let payload):
            self.writeWithOutputRawSpan(minimumWritableBytes: HTTP3EncodedLength.goawayFrame(payload.id)) {
                $0.appendHTTP3GoawayFrame(payload.id)
            }
        case .maxPushID(let payload):
            self.writeWithOutputRawSpan(minimumWritableBytes: HTTP3EncodedLength.maxPushIDFrame(payload.id)) {
                $0.appendHTTP3MaxPushIDFrame(payload.id)
            }
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
        self.writeWithOutputRawSpan(
            minimumWritableBytes: HTTP3EncodedLength.headersFrame(maxPayloadLength: maxPayloadLength)
        ) { output in
            output.appendHTTP3HeadersFrame(maxPayloadLength: maxPayloadLength, encodePayload: encodePayload)
        }
    }
}
