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

/// An HTTP/3 error code.
///
/// HTTP/3 uses error codes to communicate what went wrong when abruptly
/// terminating streams, aborting reading of streams, or immediately closing
/// connections. See RFC 9114 § 8.1.
///
/// This is modeled as a struct rather than an enum so that codes registered by
/// future revisions or extensions can be added without a source-breaking
/// change, and so that a code received from a peer is preserved verbatim even
/// when this library does not recognize it (mirroring `HTTP2ErrorCode`).
public struct HTTP3ErrorCode: Hashable, Sendable {
    /// The underlying error code value (RFC 9114 § 8.1 / RFC 9000 § 20.2).
    public var rawValue: UInt64

    /// Create an ``HTTP3ErrorCode`` from its raw value.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// No error. This is used when the connection or stream needs to be closed, but there is no error to signal.
    public static let noError = HTTP3ErrorCode(rawValue: 0x0100)
    /// Peer violated protocol requirements in a way that does not match a more specific error code or endpoint declines to use the more specific error code.
    public static let generalProtocolError = HTTP3ErrorCode(rawValue: 0x0101)
    /// An internal error has occurred in the HTTP stack.
    public static let internalError = HTTP3ErrorCode(rawValue: 0x0102)
    /// The endpoint detected that its peer created a stream that it will not accept.
    public static let streamCreationError = HTTP3ErrorCode(rawValue: 0x0103)
    /// A stream required by the HTTP/3 connection was closed or reset.
    public static let closedCriticalStream = HTTP3ErrorCode(rawValue: 0x0104)
    /// A frame was received that was not permitted in the current state or on the current stream.
    public static let frameUnexpected = HTTP3ErrorCode(rawValue: 0x0105)
    /// A frame that fails to satisfy layout requirements or with an invalid size was received.
    public static let frameError = HTTP3ErrorCode(rawValue: 0x0106)
    /// The endpoint detected that its peer is exhibiting a behavior that might be generating excessive load.
    public static let excessiveLoad = HTTP3ErrorCode(rawValue: 0x0107)
    /// A stream ID or push ID was used incorrectly, such as exceeding a limit, reducing a limit, or being reused.
    public static let idError = HTTP3ErrorCode(rawValue: 0x0108)
    /// An endpoint detected an error in the payload of a SETTINGS frame.
    public static let settingsError = HTTP3ErrorCode(rawValue: 0x0109)
    /// No SETTINGS frame was received at the beginning of the control stream.
    public static let missingSettings = HTTP3ErrorCode(rawValue: 0x010a)
    /// A server rejected a request without performing any application processing.
    public static let requestRejected = HTTP3ErrorCode(rawValue: 0x010b)
    /// The request or its response (including pushed response) is cancelled.
    public static let requestCancelled = HTTP3ErrorCode(rawValue: 0x010c)
    /// The client's stream terminated without containing a fully formed request.
    public static let requestIncomplete = HTTP3ErrorCode(rawValue: 0x010d)
    /// An HTTP message was malformed and cannot be processed.
    public static let messageError = HTTP3ErrorCode(rawValue: 0x010e)
    /// The TCP connection established in response to a CONNECT request was reset or abnormally closed.
    public static let connectError = HTTP3ErrorCode(rawValue: 0x010f)
    /// The requested operation cannot be served over HTTP/3. The peer should retry over HTTP/1.1.
    public static let versionFallback = HTTP3ErrorCode(rawValue: 0x0110)

    // MARK: QPACK (RFC 9204)

    /// The decoder failed to interpret an encoded field section and is not able to continue decoding that field section.
    public static let qpackDecompressionFailed = HTTP3ErrorCode(rawValue: 0x0200)
    /// The decoder failed to interpret an encoder instruction received on the encoder stream.
    public static let qpackEncoderStreamError = HTTP3ErrorCode(rawValue: 0x0201)
    /// The encoder failed to interpret a decoder instruction received on the decoder stream.
    public static let qpackDecoderStreamError = HTTP3ErrorCode(rawValue: 0x0202)
}

extension HTTP3ErrorCode: CustomStringConvertible {
    public var description: String {
        let name: String
        switch self {
        case .noError: name = "H3_NO_ERROR"
        case .generalProtocolError: name = "H3_GENERAL_PROTOCOL_ERROR"
        case .internalError: name = "H3_INTERNAL_ERROR"
        case .streamCreationError: name = "H3_STREAM_CREATION_ERROR"
        case .closedCriticalStream: name = "H3_CLOSED_CRITICAL_STREAM"
        case .frameUnexpected: name = "H3_FRAME_UNEXPECTED"
        case .frameError: name = "H3_FRAME_ERROR"
        case .excessiveLoad: name = "H3_EXCESSIVE_LOAD"
        case .idError: name = "H3_ID_ERROR"
        case .settingsError: name = "H3_SETTINGS_ERROR"
        case .missingSettings: name = "H3_MISSING_SETTINGS"
        case .requestRejected: name = "H3_REQUEST_REJECTED"
        case .requestCancelled: name = "H3_REQUEST_CANCELLED"
        case .requestIncomplete: name = "H3_REQUEST_INCOMPLETE"
        case .messageError: name = "H3_MESSAGE_ERROR"
        case .connectError: name = "H3_CONNECT_ERROR"
        case .versionFallback: name = "H3_VERSION_FALLBACK"
        case .qpackDecompressionFailed: name = "QPACK_DECOMPRESSION_FAILED"
        case .qpackEncoderStreamError: name = "QPACK_ENCODER_STREAM_ERROR"
        case .qpackDecoderStreamError: name = "QPACK_DECODER_STREAM_ERROR"
        default: name = "UNKNOWN"
        }
        return "HTTP3ErrorCode<0x\(String(self.rawValue, radix: 16)) \(name)>"
    }
}
