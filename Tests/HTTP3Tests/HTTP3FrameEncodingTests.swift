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
import NIOQUICHelpers
@_spi(PackageInternal) import QPACK
import Testing

@_spi(PackageInternal) @testable import HTTP3

struct HTTP3FrameEncodingTests {
    // MARK: QUIC variable-length integers

    /// The values either side of each length boundary, and the largest value.
    static let varintValues: [UInt64] = [
        0, 63, 64, 16383, 16384, 1_073_741_823, 1_073_741_824, QUICEncodableInteger.maxValue,
    ]

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.varintValues)
    func varintIsMinimalAndMatchesNIO(value: UInt64) {
        let length = HTTP3FrameEncoder.Length.quicVarint(value)
        let bytes = encodeWithExactRoom(length) { $0.appendQUICVarint(value) }

        var expected = ByteBuffer()
        expected.writeEncodedInteger(value, strategy: .quic)
        #expect(bytes == Array(expected.readableBytesView))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: [1, 2, 4, 8])
    func varintOfFixedLength(length: Int) {
        let bytes = encodeWithExactRoom(length) { $0.appendQUICVarint(37, length: length) }

        var buffer = ByteBuffer(bytes: bytes)
        #expect(buffer.readEncodedInteger(as: UInt64.self, strategy: .quic) == 37)
        #expect(buffer.readableBytes == 0)
    }

    @available(anyAppleOS 27, *)
    @Test func varintLengthBoundaries() {
        #expect(Self.varintValues.map { HTTP3FrameEncoder.Length.quicVarint($0) } == [1, 1, 2, 2, 4, 4, 8, 8])
    }

    // MARK: DATA frames

    @available(anyAppleOS 27, *)
    @Test(arguments: [4, 63, 64, 16384])
    func dataFrameHeader(payloadLength: Int) throws {
        let header = encodeWithExactRoom(HTTP3FrameEncoder.Length.dataFrameHeader(payloadLength: payloadLength)) {
            HTTP3FrameEncoder.encodeDataFrameHeader(payloadLength: payloadLength, into: &$0)
        }
        let payload = ByteBuffer(repeating: 0x2A, count: payloadLength)

        let frame = try decodeFrame(header + Array(payload.readableBytesView))
        #expect(frame == .known(.data(payload)))
    }

    @available(anyAppleOS 27, *)
    @Test func dataFrameHeaderBytes() {
        let header = encodeWithExactRoom(HTTP3FrameEncoder.Length.dataFrameHeader(payloadLength: 100)) {
            HTTP3FrameEncoder.encodeDataFrameHeader(payloadLength: 100, into: &$0)
        }
        // Type 0, then the length 100 in two bytes.
        #expect(header == [0x00, 0x40, 100])
    }

    // MARK: HEADERS frames

    /// A field section of a single literal field line, `test: value`: 13 bytes.
    static let fieldSection: [UInt8] =
        [0, 0, 0b00100100] + Array("test".utf8) + [0b00000101] + Array("value".utf8)

    @available(anyAppleOS 27, *)
    @Test func headersFrameLengthIsSizedForTheMaximumPayload() {
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.headersFrame(maxPayloadLength: 100)) { output in
            HTTP3FrameEncoder.encodeHeadersFrame(maxPayloadLength: 100, into: &output) { payload in
                for byte in Self.fieldSection { payload.append(byte) }
            }
        }
        // Type 1, then the length 13 in two bytes, as 100 needs two.
        #expect(bytes == [1, 0x40, 13] + Self.fieldSection)
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: [13, 63, 64, 16384])
    func headersFrameRoundTrips(maxPayloadLength: Int) throws {
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.headersFrame(maxPayloadLength: maxPayloadLength)) {
            output in
            HTTP3FrameEncoder.encodeHeadersFrame(maxPayloadLength: maxPayloadLength, into: &output) { payload in
                for byte in Self.fieldSection { payload.append(byte) }
            }
        }

        let frame = try decodeFrame(bytes)
        #expect(frame == .known(.headers(.init(fieldSection: ByteBuffer(bytes: Self.fieldSection)))))
    }

    @available(anyAppleOS 27, *)
    @Test func headersFrameWithAPayloadOfExactlyTheMaximum() {
        let bytes = encodeWithExactRoom(
            HTTP3FrameEncoder.Length.headersFrame(maxPayloadLength: Self.fieldSection.count)
        ) {
            output in
            HTTP3FrameEncoder.encodeHeadersFrame(maxPayloadLength: Self.fieldSection.count, into: &output) { payload in
                for byte in Self.fieldSection { payload.append(byte) }
            }
        }
        #expect(bytes == [1, 13] + Self.fieldSection)
    }

    @available(anyAppleOS 27, *)
    @Test func headersFrameAppendsAfterWhatIsAlreadyThere() {
        let frameLength = HTTP3FrameEncoder.Length.headersFrame(maxPayloadLength: 20)
        let bytes = encodeWithExactRoom(2 + frameLength) { output in
            output.append(0xAA)
            output.append(0xBB)
            HTTP3FrameEncoder.encodeHeadersFrame(maxPayloadLength: 20, into: &output) { payload in
                for byte in Self.fieldSection { payload.append(byte) }
            }
        }
        #expect(bytes == [0xAA, 0xBB, 1, 13] + Self.fieldSection)
    }

    // MARK: SETTINGS frames

    @available(anyAppleOS 27, *)
    @Test func settingsFrameBytes() {
        let settings = HTTP3Settings(
            qpackMaximumTableCapacity: 151_288_809_941_952_652,
            qpackBlockedStreams: 1,
            h3Datagram: false,
            enableConnectProtocol: false
        )
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.settingsFrame(settings)) {
            HTTP3FrameEncoder.encodeSettingsFrame(settings, into: &$0)
        }
        // Type 4, length 11, then QPACK_BLOCKED_STREAMS (7) 1 and QPACK_MAX_TABLE_CAPACITY (1) in eight bytes.
        #expect(bytes == [0x04, 0x0b, 0x07, 0x01, 0x01, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c])
    }

    @available(anyAppleOS 27, *)
    @Test func settingsFrameLeavesOutDefaults() {
        let settings = HTTP3Settings(qpackBlockedStreams: 0, h3Datagram: false, enableConnectProtocol: false)
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.settingsFrame(settings)) {
            HTTP3FrameEncoder.encodeSettingsFrame(settings, into: &$0)
        }
        #expect(bytes == [0x04, 0x00])
    }

    @available(anyAppleOS 27, *)
    @Test func settingsFrameRoundTrips() throws {
        let settings = try HTTP3Settings(parsing: [
            HTTP3Setting(identifier: .qpackMaximumTableCapacity, value: 4096),
            HTTP3Setting(identifier: .qpackBlockedStreams, value: 100),
            HTTP3Setting(identifier: .maximumFieldSectionSize, value: 16384),
            HTTP3Setting(identifier: .h3Datagram, value: 1),
            HTTP3Setting(identifier: .enableConnectProtocol, value: 1),
            HTTP3Setting(identifier: .init(extensionSetting: 0x21)!, value: 1_073_741_824),
        ])
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.settingsFrame(settings)) {
            HTTP3FrameEncoder.encodeSettingsFrame(settings, into: &$0)
        }

        let frame = try decodeFrame(bytes)
        #expect(frame == .known(.settings(settings)))
    }

    // MARK: Frames carrying a single integer

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.varintValues)
    func goawayFrame(id: UInt64) throws {
        let goawayID = HTTP3GoawayID(rawValue: id)
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.goawayFrame(goawayID)) {
            HTTP3FrameEncoder.encodeGoawayFrame(goawayID, into: &$0)
        }
        #expect(try decodeFrame(bytes) == .known(.goaway(goawayID)))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.varintValues)
    func maxPushIDFrame(id: UInt64) throws {
        let pushID = HTTP3PushID(rawValue: id)
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.maxPushIDFrame(pushID)) {
            HTTP3FrameEncoder.encodeMaxPushIDFrame(pushID, into: &$0)
        }
        #expect(try decodeFrame(bytes) == .known(.maxPushID(pushID)))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.varintValues)
    func cancelPushFrame(id: UInt64) throws {
        let pushID = HTTP3PushID(rawValue: id)
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.cancelPushFrame(pushID)) {
            HTTP3FrameEncoder.encodeCancelPushFrame(pushID, into: &$0)
        }
        #expect(try decodeFrame(bytes) == .known(.cancelPush(pushID)))
    }

    @available(anyAppleOS 27, *)
    @Test func goawayFrameBytes() {
        let goawayID: HTTP3GoawayID = 151_288_809_941_952_652
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.goawayFrame(goawayID)) {
            HTTP3FrameEncoder.encodeGoawayFrame(goawayID, into: &$0)
        }
        // Type 7, length 8, then the id in eight bytes.
        #expect(bytes == [0x07, 0x08, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c])
    }

    // MARK: Stream types

    @available(anyAppleOS 27, *)
    @Test(arguments: [
        HTTP3StreamType.Unidirectional.control, .push, .qpackEncoder, .qpackDecoder, .unknown(raw: 0x21),
    ])
    func streamType(_ type: HTTP3StreamType.Unidirectional) {
        let bytes = encodeWithExactRoom(HTTP3FrameEncoder.Length.streamType(type)) {
            HTTP3FrameEncoder.encodeStreamType(type, into: &$0)
        }

        var buffer = ByteBuffer(bytes: bytes)
        #expect(buffer.readEncodedInteger(as: UInt64.self, strategy: .quic) == type.rawValue)
        #expect(buffer.readableBytes == 0)
    }
}

/// Runs `encode` on a span of exactly `length` bytes and returns what it wrote. A `length` that is too small traps.
@available(anyAppleOS 27, *)
private func encodeWithExactRoom(_ length: Int, _ encode: (inout OutputRawSpan) -> Void) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: length)
    let written = bytes.withUnsafeMutableBytes { buffer in
        var output = OutputRawSpan(buffer: buffer, initializedCount: 0)
        encode(&output)
        return output.finalize(for: buffer)
    }
    bytes.removeLast(length - written)
    return bytes
}

/// Decodes `bytes`, which hold exactly one frame.
@available(anyAppleOS 27, *)
private func decodeFrame(
    _ bytes: [UInt8],
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> HTTP3PartialFrameOrUnknown? {
    var decoder = HTTP3FrameDecoder()
    var buffer = ByteBuffer(bytes: bytes)
    let frame = try decoder.decode(buffer: &buffer)
    #expect(buffer.readableBytes == 0, sourceLocation: sourceLocation)
    return frame
}
