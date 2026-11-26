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

/// Validates the order of the messages on a request stream (RFC 9114 § 4.1).
///
/// "Inbound" is the peer's message: the request for a server, the response for a client. Each message is a head (for
/// a response, possibly preceded by interim responses), any number of body parts, and optional trailers.
///
/// The validator works on message events rather than frames, so it doesn't care how the frames are parsed or encoded:
/// ``receivedFrame(_:)`` checks the type of the next frame before its payload is parsed, and
/// ``receivedHead(informational:)`` records the head once it has been decoded. ``receivedEnd()`` records the FIN.
///
/// A rejected event leaves the state as it was. The validator doesn't remember errors: the caller decides what an
/// error means for the stream, and stops using the validator once the stream failed.
@available(anyAppleOS 27, *)
package struct HTTP3RequestStreamValidator: Sendable {
    private enum InboundState {
        /// Waiting for the (final) head. Interim responses bring a client back here. A HEADERS frame moves to
        /// `decodingHead`.
        case awaitingHead
        /// ``InboundFrameAction/decodeHead`` announced a head, which hasn't been recorded yet. An informational head
        /// moves back to `awaitingHead`, any other head to `awaitingBodyOrTrailers`.
        case decodingHead
        /// The final head was recorded. Trailers or the FIN move to `ended`.
        case awaitingBodyOrTrailers
        /// Trailers or the FIN ended the message. No more frames may follow.
        case ended
    }

    /// Whether this is the client's or the server's end of the stream.
    let connectionType: HTTP3ConnectionType

    private var inbound: InboundState

    private var isServer: Bool {
        self.connectionType == .server
    }

    package init(connectionType: HTTP3ConnectionType) {
        self.connectionType = connectionType
        self.inbound = .awaitingHead
    }

    // MARK: Inbound

    /// What to do with the next inbound frame.
    package enum InboundFrameAction: Sendable {
        /// A HEADERS frame carrying the head (possibly an interim response): decode it, then call
        /// ``HTTP3RequestStreamValidator/receivedHead(informational:)`` before validating the next frame.
        case decodeHead
        /// A HEADERS frame carrying trailers. The inbound message is complete.
        case decodeTrailers
        /// A DATA frame.
        case body
        /// A frame of an unknown type, which is ignored (RFC 9114 § 9).
        case ignore
        /// The frame is a connection error.
        case connectionError(HTTP3Error)
    }

    /// Validates the type of the next inbound frame, before its payload is parsed.
    ///
    /// - Precondition: Traps if called after a previous ``receivedFrame`` returned ``InboundFrameAction/decodeHead``, without
    ///                 a call to ``receivedHead(informational:)`` in between.
    package mutating func receivedFrame(_ type: HTTP3FrameType) -> InboundFrameAction {
        switch (type, self.inbound) {
        case (_, .decodingHead):
            // The peer did nothing wrong: we validated a frame before recording the head.
            preconditionFailure("A frame was validated before the head announced by decodeHead was recorded")

        case (.headers, .awaitingHead):
            self.inbound = .decodingHead
            return .decodeHead
        case (.headers, .awaitingBodyOrTrailers):
            self.inbound = .ended
            return .decodeTrailers
        case (.data, .awaitingBodyOrTrailers):
            return .body
        case (.headers, .ended), (.data, .awaitingHead), (.data, .ended):
            // RFC 9114 § 4.1: receipt of an invalid sequence of frames MUST be treated as a connection error of type
            // H3_FRAME_UNEXPECTED.
            return .connectionError(self.unexpectedFrameError(type: type, location: .here()))

        case (.unknown, _):
            // RFC 9114 § 9: frames of unknown types MUST be ignored.
            return .ignore

        case (.pushPromise, _):
            if self.isServer {
                // RFC 9114 § 7.2.5: a client MUST NOT send a PUSH_PROMISE frame. A server MUST treat the receipt of a
                // PUSH_PROMISE frame as a connection error of type H3_FRAME_UNEXPECTED.
                return .connectionError(self.unexpectedFrameError(type: type, location: .here()))
            } else {
                // RFC 9114 § 7.2.5: a client MUST treat receipt of a PUSH_PROMISE frame that contains a larger push ID
                // than the client has advertised as a connection error of H3_ID_ERROR. We never send MAX_PUSH_ID, so
                // every push ID is larger than the one we advertised.
                return .connectionError(Self.unexpectedPushPromiseError(location: .here()))
            }

        case (.settings, _), (.goaway, _), (.maxPushID, _), (.cancelPush, _):
            // RFC 9114 § 7.2: these frames are only allowed on the control stream.
            return .connectionError(self.unexpectedFrameError(type: type, location: .here()))
        }
    }

    /// Records the decoded head announced by ``InboundFrameAction/decodeHead``.
    ///
    /// - Parameter informational: Whether the head is an interim (1xx) response, which keeps waiting for the final
    ///   head. Only a client receives responses, so a server must always pass `false`.
    package mutating func receivedHead(informational: Bool) {
        precondition(!(informational && self.isServer), "A request can't be informational")
        precondition(self.inbound == .decodingHead, "A head was received which wasn't announced by decodeHead")
        // RFC 9114 § 4.1: a response MAY consist of multiple messages when and only when one or more interim
        // responses (1xx) precede a final response to the same request.
        self.inbound = informational ? .awaitingHead : .awaitingBodyOrTrailers
    }

    /// What to do when the peer finished its side of the stream.
    package enum InboundEndAction: Sendable {
        /// The inbound message was complete.
        case complete
        /// A server's request ended before its head: reset the stream with H3_REQUEST_INCOMPLETE (RFC 9114 § 4.1).
        case incompleteRequest(HTTP3Error)
        /// A client's response ended before its final head: tell the user, it must not be used (RFC 9114 § 4.1.1).
        case incompleteResponse(HTTP3Error)
    }

    /// Records that the peer finished its side of the stream (FIN).
    package mutating func receivedEnd() -> InboundEndAction {
        switch self.inbound {
        case .awaitingHead, .decodingHead:
            // A head which was announced but not recorded hasn't been received. Callers record the head before they
            // handle the FIN. If one doesn't, an incomplete message is safer than trapping on the peer's FIN.
            if self.isServer {
                // RFC 9114 § 4.1: if a client-initiated stream terminates without enough of the HTTP message to
                // provide a complete response, the server SHOULD abort its response stream with the error code
                // H3_REQUEST_INCOMPLETE.
                return .incompleteRequest(
                    HTTP3Error(
                        code: .peerTerminatedInboundStream,
                        message: "Inbound request stream closed before a complete request was received",
                        cause: nil,
                        errorCode: .requestIncomplete,
                        location: .here()
                    )
                )
            } else {
                // RFC 9114 § 4.1.1: if a stream is cancelled after receiving a partial response, the response SHOULD
                // NOT be used. This is not a stream or connection error: it's up to the user what to do.
                return .incompleteResponse(
                    HTTP3Error(
                        code: .peerTerminatedInboundStream,
                        message: "Inbound response stream closed before a complete response was received",
                        cause: nil,
                        errorCode: nil,
                        location: .here()
                    )
                )
            }

        case .awaitingBodyOrTrailers, .ended:
            // TODO: If a Content-Length header was specified, we need to check whether we have received all the
            // specified bytes. If that is not the case, then the message is malformed per RFC 9114 § 4.1.2, and it
            // must be treated as a stream error.
            self.inbound = .ended
            return .complete
        }
    }

    // MARK: Errors

    @inline(never)
    private func unexpectedFrameError(type: HTTP3FrameType, location: HTTP3Error.SourceLocation) -> HTTP3Error {
        let expected =
            switch self.inbound {
            case .awaitingHead, .decodingHead: "headers"
            case .awaitingBodyOrTrailers: "headers or data"
            case .ended:
                self.isServer ? "no further frames after request trailers" : "no further frames after response trailers"
            }
        return HTTP3Error(
            code: .unexpectedFrame,
            message: "Expected \(expected), got \(type)",
            cause: nil,
            errorCode: .frameUnexpected,
            location: location
        )
    }

    @inline(never)
    private static func unexpectedPushPromiseError(location: HTTP3Error.SourceLocation) -> HTTP3Error {
        HTTP3Error(
            code: .unexpectedFrame,
            message: "Unexpected push promise",
            cause: nil,
            errorCode: .idError,
            location: location
        )
    }
}
