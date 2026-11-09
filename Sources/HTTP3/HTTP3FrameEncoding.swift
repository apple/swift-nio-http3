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

import NIOQUICHelpers

extension OutputRawSpan {
    /// Appends the type and length of a DATA frame. The payload must follow.
    ///
    /// - Precondition: The span has room for ``HTTP3EncodedLength/dataFrameHeader(payloadLength:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendHTTP3DataFrameHeader(payloadLength: Int) {
        self.appendQUICVarint(HTTP3FrameType.data.rawValue)
        self.appendQUICVarint(UInt64(payloadLength))
    }

    /// Appends a HEADERS frame, whose payload `encodePayload` appends.
    ///
    /// The length is sized for `maxPayloadLength`, so it may take more bytes than the payload needs.
    ///
    /// - Parameters:
    ///   - maxPayloadLength: The largest number of bytes `encodePayload` appends.
    ///   - encodePayload: Appends the QPACK encoded field section.
    /// - Precondition: The span has room for ``HTTP3EncodedLength/headersFrame(maxPayloadLength:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendHTTP3HeadersFrame(maxPayloadLength: Int, encodePayload: (inout OutputRawSpan) -> Void) {
        precondition(maxPayloadLength >= 0, "Negative maximum payload length")
        self.appendQUICVarint(HTTP3FrameType.headers.rawValue)
        let lengthLength = HTTP3EncodedLength.quicVarint(UInt64(maxPayloadLength))
        self.withUnsafeMutableBytes { buffer, initializedCount in
            let lengthStart = initializedCount
            let payloadStart = lengthStart &+ lengthLength
            precondition(
                payloadStart &+ maxPayloadLength <= buffer.count,
                "Not enough room for the HEADERS frame"
            )

            let payloadBuffer = UnsafeMutableRawBufferPointer(
                rebasing: buffer[payloadStart..<(payloadStart &+ maxPayloadLength)]
            )
            var payloadOutput = OutputRawSpan(buffer: payloadBuffer, initializedCount: 0)
            encodePayload(&payloadOutput)
            let payloadLength = payloadOutput.finalize(for: payloadBuffer)

            let lengthBuffer = UnsafeMutableRawBufferPointer(rebasing: buffer[lengthStart..<payloadStart])
            var lengthOutput = OutputRawSpan(buffer: lengthBuffer, initializedCount: 0)
            lengthOutput.appendQUICVarint(UInt64(payloadLength), length: lengthLength)
            _ = lengthOutput.finalize(for: lengthBuffer)

            initializedCount = payloadStart &+ payloadLength
        }
    }

    /// Appends a SETTINGS frame. Settings which have their default value are left out.
    ///
    /// - Precondition: The span has room for ``HTTP3EncodedLength/settingsFrame(_:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendHTTP3SettingsFrame(_ settings: HTTP3Settings) {
        self.appendQUICVarint(HTTP3FrameType.settings.rawValue)
        self.appendQUICVarint(UInt64(HTTP3EncodedLength.settingsPayload(settings)))
        settings.forEachNonDefaultSetting { identifier, value in
            self.appendQUICVarint(identifier)
            self.appendQUICVarint(value)
        }
    }

    /// Appends a GOAWAY frame.
    ///
    /// - Precondition: The span has room for ``HTTP3EncodedLength/goawayFrame(_:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendHTTP3GoawayFrame(_ id: HTTP3GoawayID) {
        self.appendHTTP3SingleIntegerFrame(type: .goaway, value: id.rawValue)
    }

    /// Appends a MAX_PUSH_ID frame.
    ///
    /// - Precondition: The span has room for ``HTTP3EncodedLength/maxPushIDFrame(_:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendHTTP3MaxPushIDFrame(_ id: HTTP3PushID) {
        self.appendHTTP3SingleIntegerFrame(type: .maxPushID, value: id.rawValue)
    }

    /// Appends a CANCEL_PUSH frame.
    ///
    /// - Precondition: The span has room for ``HTTP3EncodedLength/cancelPushFrame(_:)`` more bytes.
    @available(anyAppleOS 27, *)
    mutating func appendHTTP3CancelPushFrame(_ id: HTTP3PushID) {
        self.appendHTTP3SingleIntegerFrame(type: .cancelPush, value: id.rawValue)
    }

    /// Appends the type which starts a unidirectional stream (RFC 9114 § 6.2).
    ///
    /// - Precondition: The span has room for ``HTTP3EncodedLength/streamType(_:)`` more bytes.
    @available(anyAppleOS 27, *)
    @_spi(PackageInternal)
    public mutating func appendHTTP3StreamType(_ type: HTTP3StreamType.Unidirectional) {
        self.appendQUICVarint(type.rawValue)
    }

    /// Appends a frame whose payload is a single variable-length integer.
    @available(anyAppleOS 27, *)
    private mutating func appendHTTP3SingleIntegerFrame(type: HTTP3FrameType, value: UInt64) {
        self.appendQUICVarint(type.rawValue)
        self.appendQUICVarint(UInt64(HTTP3EncodedLength.quicVarint(value)))
        self.appendQUICVarint(value)
    }
}

/// The number of bytes HTTP/3 frames take on the wire.
@available(anyAppleOS 27, *)
public enum HTTP3EncodedLength {
    /// The number of bytes ``OutputRawSpan/appendHTTP3DataFrameHeader(payloadLength:)`` appends.
    static func dataFrameHeader(payloadLength: Int) -> Int {
        Self.quicVarint(HTTP3FrameType.data.rawValue) &+ Self.quicVarint(UInt64(payloadLength))
    }

    /// The largest number of bytes ``OutputRawSpan/appendHTTP3HeadersFrame(maxPayloadLength:encodePayload:)`` appends.
    static func headersFrame(maxPayloadLength: Int) -> Int {
        Self.quicVarint(HTTP3FrameType.headers.rawValue) &+ Self.quicVarint(UInt64(maxPayloadLength))
            &+ maxPayloadLength
    }

    /// The number of bytes ``OutputRawSpan/appendHTTP3SettingsFrame(_:)`` appends.
    static func settingsFrame(_ settings: HTTP3Settings) -> Int {
        let payloadLength = Self.settingsPayload(settings)
        return Self.quicVarint(HTTP3FrameType.settings.rawValue) &+ Self.quicVarint(UInt64(payloadLength))
            &+ payloadLength
    }

    /// The number of bytes ``OutputRawSpan/appendHTTP3GoawayFrame(_:)`` appends.
    static func goawayFrame(_ id: HTTP3GoawayID) -> Int {
        Self.singleIntegerFrame(type: .goaway, value: id.rawValue)
    }

    /// The number of bytes ``OutputRawSpan/appendHTTP3MaxPushIDFrame(_:)`` appends.
    static func maxPushIDFrame(_ id: HTTP3PushID) -> Int {
        Self.singleIntegerFrame(type: .maxPushID, value: id.rawValue)
    }

    /// The number of bytes ``OutputRawSpan/appendHTTP3CancelPushFrame(_:)`` appends.
    static func cancelPushFrame(_ id: HTTP3PushID) -> Int {
        Self.singleIntegerFrame(type: .cancelPush, value: id.rawValue)
    }

    /// The number of bytes ``OutputRawSpan/appendHTTP3StreamType(_:)`` appends.
    public static func streamType(_ type: HTTP3StreamType.Unidirectional) -> Int {
        Self.quicVarint(type.rawValue)
    }

    /// The number of bytes ``OutputRawSpan/appendQUICVarint(_:)`` appends for `value`.
    ///
    /// - Precondition: `value` is at most `QUICEncodableInteger.maxValue`.
    static func quicVarint(_ value: UInt64) -> Int {
        switch value {
        case 0...63: return 1
        case 0...16383: return 2
        case 0...1_073_741_823: return 4
        default:
            precondition(
                value <= QUICEncodableInteger.maxValue,
                "\(value) is too large for a QUIC variable-length integer"
            )
            return 8
        }
    }

    /// The length of a SETTINGS frame's payload.
    static func settingsPayload(_ settings: HTTP3Settings) -> Int {
        var length = 0
        settings.forEachNonDefaultSetting { identifier, value in
            length &+= Self.quicVarint(identifier) &+ Self.quicVarint(value)
        }
        return length
    }

    private static func singleIntegerFrame(type: HTTP3FrameType, value: UInt64) -> Int {
        let valueLength = Self.quicVarint(value)
        return Self.quicVarint(type.rawValue) &+ Self.quicVarint(UInt64(valueLength)) &+ valueLength
    }
}

// MARK: QUIC variable-length integers

extension OutputRawSpan {
    /// Appends `value` as a QUIC variable-length integer, in as few bytes as possible (RFC 9000 § 16).
    ///
    /// - Precondition: The span has room for ``HTTP3EncodedLength/quicVarint(_:)`` more bytes, and `value` is at most
    ///   `QUICEncodableInteger.maxValue`.
    @available(anyAppleOS 27, *)
    mutating func appendQUICVarint(_ value: UInt64) {
        self.appendQUICVarint(value, length: HTTP3EncodedLength.quicVarint(value))
    }

    /// Appends `value` as a QUIC variable-length integer of `length` bytes, which may be more than it needs.
    ///
    /// - Precondition: `length` is 1, 2, 4 or 8, `value` fits in it, and the span has room for it.
    @available(anyAppleOS 27, *)
    mutating func appendQUICVarint(_ value: UInt64, length: Int) {
        // A length of 1, 2, 4 or 8 leaves 6, 14, 30 or 62 bits for the value.
        let valueBits = length &* 8 &- 2
        precondition(
            length == 1 || length == 2 || length == 4 || length == 8,
            "Invalid QUIC variable-length integer length \(length)"
        )
        precondition(
            value >> valueBits == 0,
            "\(value) doesn't fit in a QUIC variable-length integer of \(length) bytes"
        )

        // The two most significant bits of the first byte give the length: 00 for 1, 01 for 2, 10 for 4 and 11 for 8.
        switch length {
        case 1: self.append(UInt8(truncatingIfNeeded: value), as: UInt8.self)
        case 2: self.append(UInt16(truncatingIfNeeded: value) | 0x4000, as: UInt16.self, .bigEndian)
        case 4: self.append(UInt32(truncatingIfNeeded: value) | 0x8000_0000, as: UInt32.self, .bigEndian)
        default: self.append(value | 0xC000_0000_0000_0000, as: UInt64.self, .bigEndian)
        }
    }
}
