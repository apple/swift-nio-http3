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

import HTTP3
import NIOCore

extension ByteBuffer {
    /// Write a single `HTTP3Frame` into the ByteBuffer, and move the writer index to just after the frame.
    ///
    /// HEADERS frames need QPACK encoding, so they are written through
    /// ``writeHeadersFrame(maxPayloadLength:encodePayload:)`` instead, and PUSH_PROMISE frames are never written. It
    /// is a fatal error to call this function with either.
    /// - Parameter frame: The frame to be written to the `ByteBuffer`.
    @available(anyAppleOS 27, *)
    mutating func writeHTTP3Frame(_ frame: HTTP3Frame) {
        switch frame {
        case .data(let payload):
            let payloadLength = payload.payload.readableBytes
            self.writeWithOutputRawSpan(
                minimumWritableBytes: HTTP3FrameEncoder.Length.dataFrameHeader(payloadLength: payloadLength)
            ) {
                HTTP3FrameEncoder.encodeDataFrameHeader(payloadLength: payloadLength, into: &$0)
            }
            self.writeImmutableBuffer(payload.payload)
        case .headers:
            fatalError("HEADERS frames are written through writeHeadersFrame(maxPayloadLength:encodePayload:)")
        case .cancelPush(let payload):
            self.writeWithOutputRawSpan(
                minimumWritableBytes: HTTP3FrameEncoder.Length.cancelPushFrame(payload.pushID)
            ) {
                HTTP3FrameEncoder.encodeCancelPushFrame(payload.pushID, into: &$0)
            }
        case .settings(let payload):
            self.writeWithOutputRawSpan(
                minimumWritableBytes: HTTP3FrameEncoder.Length.settingsFrame(payload.settings)
            ) {
                HTTP3FrameEncoder.encodeSettingsFrame(payload.settings, into: &$0)
            }
        case .pushPromise:
            fatalError("Writing PUSH_PROMISE frames is not supported")
        case .goaway(let payload):
            self.writeWithOutputRawSpan(minimumWritableBytes: HTTP3FrameEncoder.Length.goawayFrame(payload.id)) {
                HTTP3FrameEncoder.encodeGoawayFrame(payload.id, into: &$0)
            }
        case .maxPushID(let payload):
            self.writeWithOutputRawSpan(minimumWritableBytes: HTTP3FrameEncoder.Length.maxPushIDFrame(payload.id)) {
                HTTP3FrameEncoder.encodeMaxPushIDFrame(payload.id, into: &$0)
            }
        }
    }

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
            minimumWritableBytes: HTTP3FrameEncoder.Length.headersFrame(maxPayloadLength: maxPayloadLength)
        ) { output in
            HTTP3FrameEncoder.encodeHeadersFrame(
                maxPayloadLength: maxPayloadLength,
                into: &output,
                encodePayload: encodePayload
            )
        }
    }
}
