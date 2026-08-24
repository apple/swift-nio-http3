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
/// HTTP/3 uses error codes to communicate what went wrong when abruptly
/// terminating streams, aborting reading of streams, or immediately closing
/// connections. See RFC 9114 § 8.1.
///
/// This is modeled as a struct rather than an enum so that a code received from
/// a peer is preserved verbatim even when this library does not recognize it
/// (mirroring `HTTP2ErrorCode`).
public struct HTTP3ErrorCode: Hashable, Sendable {
    /// The underlying error code value (RFC 9114 § 8.1 / RFC 9000 § 20.2).
    public var rawValue: UInt64

    /// Create an ``HTTP3ErrorCode`` from its raw value.
    @inlinable
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// No error. This is used when the connection or stream needs to be closed, but there is no error to signal.
    @inlinable
    public static var noError: HTTP3ErrorCode { Self(rawValue: 0x0100) }
    /// Peer violated protocol requirements in a way that does not match a more specific error code or endpoint declines to use the more specific error code.
    @inlinable
    public static var generalProtocolError: HTTP3ErrorCode { Self(rawValue: 0x0101) }
    /// An internal error has occurred in the HTTP stack.
    @inlinable
    public static var internalError: HTTP3ErrorCode { Self(rawValue: 0x0102) }
    /// The endpoint detected that its peer created a stream that it will not accept.
    @inlinable
    public static var streamCreationError: HTTP3ErrorCode { Self(rawValue: 0x0103) }
    /// A stream required by the HTTP/3 connection was closed or reset.
    @inlinable
    public static var closedCriticalStream: HTTP3ErrorCode { Self(rawValue: 0x0104) }
    /// A frame was received that was not permitted in the current state or on the current stream.
    @inlinable
    public static var frameUnexpected: HTTP3ErrorCode { Self(rawValue: 0x0105) }
    /// A frame that fails to satisfy layout requirements or with an invalid size was received.
    @inlinable
    public static var frameError: HTTP3ErrorCode { Self(rawValue: 0x0106) }
    /// The endpoint detected that its peer is exhibiting a behavior that might be generating excessive load.
    @inlinable
    public static var excessiveLoad: HTTP3ErrorCode { Self(rawValue: 0x0107) }
    /// A stream ID or push ID was used incorrectly, such as exceeding a limit, reducing a limit, or being reused.
    @inlinable
    public static var idError: HTTP3ErrorCode { Self(rawValue: 0x0108) }
    /// An endpoint detected an error in the payload of a SETTINGS frame.
    @inlinable
    public static var settingsError: HTTP3ErrorCode { Self(rawValue: 0x0109) }
    /// No SETTINGS frame was received at the beginning of the control stream.
    @inlinable
    public static var missingSettings: HTTP3ErrorCode { Self(rawValue: 0x010a) }
    /// A server rejected a request without performing any application processing.
    @inlinable
    public static var requestRejected: HTTP3ErrorCode { Self(rawValue: 0x010b) }
    /// The request or its response (including pushed response) is cancelled.
    @inlinable
    public static var requestCancelled: HTTP3ErrorCode { Self(rawValue: 0x010c) }
    /// The client's stream terminated without containing a fully formed request.
    @inlinable
    public static var requestIncomplete: HTTP3ErrorCode { Self(rawValue: 0x010d) }
    /// An HTTP message was malformed and cannot be processed.
    @inlinable
    public static var messageError: HTTP3ErrorCode { Self(rawValue: 0x010e) }
    /// The TCP connection established in response to a CONNECT request was reset or abnormally closed.
    @inlinable
    public static var connectError: HTTP3ErrorCode { Self(rawValue: 0x010f) }
    /// The requested operation cannot be served over HTTP/3. The peer should retry over HTTP/1.1.
    @inlinable
    public static var versionFallback: HTTP3ErrorCode { Self(rawValue: 0x0110) }

    // MARK: QPACK (RFC 9204)

    /// The decoder failed to interpret an encoded field section and is not able to continue decoding that field section.
    @inlinable
    public static var qpackDecompressionFailed: HTTP3ErrorCode { Self(rawValue: 0x0200) }
    /// The decoder failed to interpret an encoder instruction received on the encoder stream.
    @inlinable
    public static var qpackEncoderStreamError: HTTP3ErrorCode { Self(rawValue: 0x0201) }
    /// The encoder failed to interpret a decoder instruction received on the decoder stream.
    @inlinable
    public static var qpackDecoderStreamError: HTTP3ErrorCode { Self(rawValue: 0x0202) }

    // MARK: Datagrams and Capsule (RFC 9297)

    /// Datagram or Capsule protocol parse error.
    @inlinable
    public static var datagramError: HTTP3ErrorCode { Self(rawValue: 0x33) }
}

extension HTTP3ErrorCode: CustomDebugStringConvertible {
    public var debugDescription: String {
        let name: String
        switch self {
        case .noError: name = "No Error"
        case .generalProtocolError: name = "General Protocol Error"
        case .internalError: name = "Internal Error"
        case .streamCreationError: name = "Stream Creation Error"
        case .closedCriticalStream: name = "Closed Critical Stream"
        case .frameUnexpected: name = "Frame Unexpected"
        case .frameError: name = "Frame Error"
        case .excessiveLoad: name = "Excessive Load"
        case .idError: name = "ID Error"
        case .settingsError: name = "Settings Error"
        case .missingSettings: name = "Missing Settings"
        case .requestRejected: name = "Request Rejected"
        case .requestCancelled: name = "Request Cancelled"
        case .requestIncomplete: name = "Request Incomplete"
        case .messageError: name = "Message Error"
        case .connectError: name = "Connect Error"
        case .versionFallback: name = "Version Fallback"
        case .qpackDecompressionFailed: name = "QPACK Decompression Failed"
        case .qpackEncoderStreamError: name = "QPACK Encoder Stream Error"
        case .qpackDecoderStreamError: name = "QPACK Decoder Stream Error"
        case .datagramError: name = "Datagram Error"
        default: name = "Unknown Error"
        }
        return "HTTP3ErrorCode<0x\(String(self.rawValue, radix: 16)) \(name)>"
    }
}
