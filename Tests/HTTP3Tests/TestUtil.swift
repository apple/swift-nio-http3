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
@_spi(PackageInternal) @testable import QPACK

extension String {
    @available(anyAppleOS 27, *)
    var huffmanEncodedBytes: [UInt8] {
        let length = self.withContiguousUTF8 { QPACKEncodedLength.huffman(of: $0) }
        let buffer = ByteBuffer(initialCapacity: length) { output in
            self.withContiguousUTF8 { output.appendHuffmanEncoded($0, encodedByteLength: length) }
        }
        return Array(buffer.readableBytesView)
    }
}

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
    /// Write `frame`. HEADERS and PUSH_PROMISE frames are written with their encoded field sections as they are.
    @available(anyAppleOS 27, *)
    mutating func writeTestFrame(_ frame: HTTP3PartialFrame) {
        switch frame {
        case .headers(let payload):
            self.writeEncodedInteger(HTTP3FrameType.headers.rawValue, strategy: .quic)
            self.writeLengthPrefixed(strategy: .quic) { tempBuffer in
                tempBuffer.writeImmutableBuffer(payload.fieldSection)
            }
        case .pushPromise(let payload):
            self.writeEncodedInteger(HTTP3FrameType.pushPromise.rawValue, strategy: .quic)
            self.writeLengthPrefixed(strategy: .quic) { tempBuffer in
                tempBuffer.writeEncodedInteger(payload.pushID.rawValue, strategy: .quic)
                    + tempBuffer.writeImmutableBuffer(payload.fieldSection)
            }
        case .data(let payload):
            let payloadLength = payload.payload.readableBytes
            self.writeWithOutputRawSpan(
                minimumWritableBytes: HTTP3FrameEncoder.Length.dataFrameHeader(payloadLength: payloadLength)
            ) {
                HTTP3FrameEncoder.encodeDataFrameHeader(payloadLength: payloadLength, into: &$0)
            }
            self.writeImmutableBuffer(payload.payload)
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

    /// Write a HEADERS frame whose payload `encodePayload` appends, with its length sized for `maxPayloadLength`.
    @available(anyAppleOS 27, *)
    mutating func writeTestHeadersFrame(maxPayloadLength: Int, encodePayload: (inout OutputRawSpan) -> Void) {
        self.writeWithOutputRawSpan(
            minimumWritableBytes: HTTP3FrameEncoder.Length.headersFrame(maxPayloadLength: maxPayloadLength)
        ) {
            HTTP3FrameEncoder.encodeHeadersFrame(
                maxPayloadLength: maxPayloadLength,
                into: &$0,
                encodePayload: encodePayload
            )
        }
    }
}
