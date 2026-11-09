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
        let length = HTTP3EncodedLength.quicVarint(value)
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
        #expect(Self.varintValues.map { HTTP3EncodedLength.quicVarint($0) } == [1, 1, 2, 2, 4, 4, 8, 8])
    }

    // MARK: DATA frames

    @available(anyAppleOS 27, *)
    @Test(arguments: [4, 63, 64, 16384])
    func dataFrameHeader(payloadLength: Int) throws {
        let header = encodeWithExactRoom(HTTP3EncodedLength.dataFrameHeader(payloadLength: payloadLength)) {
            $0.appendHTTP3DataFrameHeader(payloadLength: payloadLength)
        }
        let payload = ByteBuffer(repeating: 0x2A, count: payloadLength)

        let frame = try decodeFrame(header + Array(payload.readableBytesView))
        #expect(frame == .known(.data(payload)))
    }

    @available(anyAppleOS 27, *)
    @Test func dataFrameHeaderBytes() {
        let header = encodeWithExactRoom(HTTP3EncodedLength.dataFrameHeader(payloadLength: 100)) {
            $0.appendHTTP3DataFrameHeader(payloadLength: 100)
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
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.headersFrame(maxPayloadLength: 100)) { output in
            output.appendHTTP3HeadersFrame(maxPayloadLength: 100) { payload in
                for byte in Self.fieldSection { payload.append(byte) }
            }
        }
        // Type 1, then the length 13 in two bytes, as 100 needs two.
        #expect(bytes == [1, 0x40, 13] + Self.fieldSection)
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: [13, 63, 64, 16384])
    func headersFrameRoundTrips(maxPayloadLength: Int) throws {
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.headersFrame(maxPayloadLength: maxPayloadLength)) {
            output in
            output.appendHTTP3HeadersFrame(maxPayloadLength: maxPayloadLength) { payload in
                for byte in Self.fieldSection { payload.append(byte) }
            }
        }

        let frame = try decodeFrame(bytes)
        let expected = FieldSection(
            prefix: .init(encodedRequiredInsertCount: 0, deltaBase: 0, signBit: false),
            lines: [.literal(requireLiteralRepresentation: false, name: "test", value: "value")]
        )
        #expect(frame == .known(.headers(.init(fieldSection: expected))))
    }

    @available(anyAppleOS 27, *)
    @Test func headersFrameWithAPayloadOfExactlyTheMaximum() {
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.headersFrame(maxPayloadLength: Self.fieldSection.count)) {
            output in
            output.appendHTTP3HeadersFrame(maxPayloadLength: Self.fieldSection.count) { payload in
                for byte in Self.fieldSection { payload.append(byte) }
            }
        }
        #expect(bytes == [1, 13] + Self.fieldSection)
    }

    @available(anyAppleOS 27, *)
    @Test func headersFrameAppendsAfterWhatIsAlreadyThere() {
        let frameLength = HTTP3EncodedLength.headersFrame(maxPayloadLength: 20)
        let bytes = encodeWithExactRoom(2 + frameLength) { output in
            output.append(0xAA)
            output.append(0xBB)
            output.appendHTTP3HeadersFrame(maxPayloadLength: 20) { payload in
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
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.settingsFrame(settings)) {
            $0.appendHTTP3SettingsFrame(settings)
        }
        // Type 4, length 11, then QPACK_BLOCKED_STREAMS (7) 1 and QPACK_MAX_TABLE_CAPACITY (1) in eight bytes.
        #expect(bytes == [0x04, 0x0b, 0x07, 0x01, 0x01, 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c])
    }

    @available(anyAppleOS 27, *)
    @Test func settingsFrameLeavesOutDefaults() {
        let settings = HTTP3Settings(qpackBlockedStreams: 0, h3Datagram: false, enableConnectProtocol: false)
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.settingsFrame(settings)) {
            $0.appendHTTP3SettingsFrame(settings)
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
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.settingsFrame(settings)) {
            $0.appendHTTP3SettingsFrame(settings)
        }

        let frame = try decodeFrame(bytes)
        #expect(frame == .known(.settings(settings)))
    }

    // MARK: Frames carrying a single integer

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.varintValues)
    func goawayFrame(id: UInt64) throws {
        let goawayID = HTTP3GoawayID(rawValue: id)
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.goawayFrame(goawayID)) {
            $0.appendHTTP3GoawayFrame(goawayID)
        }
        #expect(try decodeFrame(bytes) == .known(.goaway(goawayID)))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.varintValues)
    func maxPushIDFrame(id: UInt64) throws {
        let pushID = HTTP3PushID(rawValue: id)
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.maxPushIDFrame(pushID)) {
            $0.appendHTTP3MaxPushIDFrame(pushID)
        }
        #expect(try decodeFrame(bytes) == .known(.maxPushID(pushID)))
    }

    @available(anyAppleOS 27, *)
    @Test(arguments: Self.varintValues)
    func cancelPushFrame(id: UInt64) throws {
        let pushID = HTTP3PushID(rawValue: id)
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.cancelPushFrame(pushID)) {
            $0.appendHTTP3CancelPushFrame(pushID)
        }
        #expect(try decodeFrame(bytes) == .known(.cancelPush(pushID)))
    }

    @available(anyAppleOS 27, *)
    @Test func goawayFrameBytes() {
        let goawayID: HTTP3GoawayID = 151_288_809_941_952_652
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.goawayFrame(goawayID)) {
            $0.appendHTTP3GoawayFrame(goawayID)
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
        let bytes = encodeWithExactRoom(HTTP3EncodedLength.streamType(type)) { $0.appendHTTP3StreamType(type) }

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
