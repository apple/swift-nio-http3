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

/// Validates incoming and outgoing frames to be a valid sequence for a given stream type.
package enum HTTP3FrameValidator: ~Copyable {
    case incomingControlStream(IncomingControlStreamValidator)
    case outgoingControlStream(OutgoingControlStreamValidator)
    case incomingPushStream(IncomingPushStreamValidator)
    case outgoingPushStream(OutgoingPushStreamValidator)
    case incomingRequestStream(ServerRequestStreamValidator)
    case outgoingRequestStream(ClientRequestStreamValidator)

    /// Checks the order of frames is valid for a control stream.
    /// I.e. first the settings, and then anything but settings after that.
    /// This works for outbound and inbound streams.
    package struct ControlStreamSequenceValidator: ~Copyable {
        private enum State: ~Copyable {
            case awaitingSettings
            case gotSettings
            case previousError
        }

        private let state: State

        init() {
            self.init(state: .awaitingSettings)
        }

        private init(state: consuming State) {
            self.state = state
        }

        mutating func processUnknownFrame() -> UnknownFrameAction {
            // RFC 9114 § 9: where a known frame type is required to be in a specific location, such as the SETTINGS frame as the first frame of
            // the control stream (see Section 6.2.1), an unknown frame type does not satisfy that requirement and SHOULD be treated as an error.
            switch consume self.state {
            case .awaitingSettings:
                self = .init(state: .previousError)
                return .emitConnectionError(
                    HTTP3Error(
                        code: .firstControlFrameNotSettings,
                        message: "Expected settings, got unknown",
                        cause: nil,
                        errorCode: .H3_MISSING_SETTINGS,
                        location: .here()
                    )
                )
            case .gotSettings:
                self = .init(state: .gotSettings)
                return .dropFrame
            case .previousError:
                self = .init(state: .previousError)
                return .previousError
            }
        }

        mutating func processNextFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            // RFC 9114 § 7.2.4: A SETTINGS frame MUST be sent as the first frame of each control stream (see Section 6.2.1) by each peer, and it MUST NOT be sent subsequently.
            // RFC 9114 § 7: Only CANCEL_PUSH, GOAWAY and MAX_PUSH_ID are allowed after the first settings frame.
            switch consume self.state {
            case .awaitingSettings:
                switch frame {
                case .settings:
                    self = .init(state: .gotSettings)
                    return .forwardFrame(frame)
                case .cancelPush, .goaway, .maxPushID, .data, .headers, .pushPromise:
                    self = .init(state: .previousError)
                    // If the first frame of the control stream is any other frame type, this MUST be treated as a connection error of type H3_MISSING_SETTINGS
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .firstControlFrameNotSettings,
                            message: "Expected settings, got \(frame.type)",
                            cause: nil,
                            errorCode: .H3_MISSING_SETTINGS,
                            location: .here()
                        )
                    )
                }
            case .gotSettings:
                switch frame {
                case .data, .headers, .pushPromise:
                    self = .init(state: .previousError)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Expected cancelPush or goaway or maxPushID, got \(frame.type)",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: .here()
                        )
                    )
                case .settings:
                    // if we already got settings, we must not get settings again
                    @inline(never)
                    func duplicateSettingsError(location: HTTP3Error.SourceLocation) -> HTTP3Error {
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Received a second settings frame",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: location
                        )
                    }
                    self = .init(state: .previousError)
                    return .emitConnectionError(duplicateSettingsError(location: .here()))
                case .cancelPush, .goaway, .maxPushID:
                    self = .init(state: .gotSettings)
                    return .forwardFrame(frame)
                }
            case .previousError:
                self = .init(state: .previousError)
                return .previousError
            }
        }
    }

    /// Checks the order of frames is valid for a push stream.
    /// TODO: https://github.com/apple/swift-nio-http3/issues/1
    /// Not implemented yet,  only validates the frame types. This works for outbound and inbound streams.
    package struct PushStreamSequenceValidator: ~Copyable {
        private enum State: ~Copyable {
            case none
            case previousError
        }

        private let state: State

        private init(state: consuming State) {
            self.state = state
        }

        init() {
            self.init(state: .none)
        }

        mutating func processNextFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            // For now, we are only implementing the frame types which are allowed
            // RFC 9114 § 7: Only headers and data frames are allowed in push streams
            switch consume self.state {
            case .none:
                switch frame {
                case .headers, .data:
                    self = .init(state: .none)
                    return .forwardFrame(frame)
                case .cancelPush, .goaway, .maxPushID, .settings, .pushPromise:
                    self = .init(state: .previousError)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Expected headers or data, got \(frame.type)",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: .here()
                        )
                    )
                }
            case .previousError:
                self = .init(state: .previousError)
                return .previousError
            }
        }
    }

    /// Checks the order of frames read and written is correct for a request stream.
    /// It looks at both request and response frames.
    /// When using this validator for a client, the request frames are the outbound and the response frames are inbound.
    /// This is reversed for a server.
    package struct RequestStreamValidator: ~Copyable {
        /// Models the state of one side of the connection.
        enum State {
            /// Nothing has happened yet.
            case idle
            /// Headers have been processed. We may or may not have also received data.
            case headersProcessed
            /// Trailers have been processed. Nothing more should be received now.
            case trailersProcessed
            /// We previously hit an error so we're refusing to do anything now.
            case previousError
        }

        private var requestState: State
        private var responseState: State

        private init(requestState: consuming State, responseState: consuming State) {
            self.requestState = requestState
            self.responseState = responseState
        }

        init() {
            self.init(requestState: .idle, responseState: .idle)
        }

        mutating func processResponseFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            let existingRequestState = self.requestState
            let existingResponseState = self.responseState
            _ = consume self  // Force us to always choose a new state
            switch (existingRequestState, existingResponseState) {
            case (.idle, _):
                // There is no request yet, we can't have a response
                self = .init(requestState: existingRequestState, responseState: .previousError)
                return .emitStreamError(
                    HTTP3Error(
                        code: .malformedMessage,
                        message: "A HTTP response was sent before a request",
                        cause: nil,
                        errorCode: .H3_MESSAGE_ERROR,
                        location: .here()
                    )
                )
            case (.previousError, _), (_, .previousError):
                // we previously hit an error, so we refuse to do anything now
                self = .init(requestState: existingRequestState, responseState: existingResponseState)
                return .previousError
            case (.headersProcessed, .idle), (.trailersProcessed, .idle):
                // response side is idle, so we haven't received anything yet. Expect head
                switch frame {
                case .headers(let headers):
                    // A response MAY consist of multiple messages when and only when one or more interim responses (1xx; see Section 15.2 of [HTTP]) precede a final response to the same request.
                    // Interim responses do not contain content or trailer sections.
                    if headers.representsInterimResponse {
                        // This header doesn't affect our state because it's interim. We just pass it through
                        self = .init(requestState: existingRequestState, responseState: existingResponseState)
                        return .forwardFrame(frame)
                    } else {
                        self = .init(requestState: existingRequestState, responseState: .headersProcessed)
                        return .forwardFrame(frame)
                    }
                case .data, .pushPromise, .maxPushID, .goaway, .settings, .cancelPush:
                    self = .init(requestState: existingRequestState, responseState: .previousError)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Expected headers, got \(frame.type)",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: .here()
                        )
                    )
                }
            case (.headersProcessed, .headersProcessed), (.trailersProcessed, .headersProcessed):
                // response side is headersProcessed. Expect data or trailers
                switch frame {
                case .headers:
                    // These are the trailers
                    self = .init(requestState: existingRequestState, responseState: .trailersProcessed)
                    return .forwardFrame(frame)
                case .data:
                    self = .init(requestState: existingRequestState, responseState: existingResponseState)
                    return .forwardFrame(frame)
                case .pushPromise, .maxPushID, .goaway, .settings, .cancelPush:
                    self = .init(requestState: existingRequestState, responseState: .previousError)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Expected headers or data, got \(frame.type)",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: .here()
                        )
                    )
                }
            case (.headersProcessed, .trailersProcessed), (.trailersProcessed, .trailersProcessed):
                switch frame {
                case .cancelPush, .goaway, .maxPushID, .settings, .pushPromise, .data, .headers:
                    // response side is trailersProcessed. We should not be receiving anything more
                    self = .init(requestState: existingRequestState, responseState: .previousError)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Expected no further frames after response trailers, got \(frame.type)",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: .here()
                        )
                    )
                }
            }
        }

        mutating func processRequestFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            // Receipt of an invalid sequence of frames MUST be treated as a connection error of type H3_FRAME_UNEXPECTED
            let existingRequestState = self.requestState
            let existingResponseState = self.responseState
            _ = consume self  // Force us to always choose a new state
            switch (existingRequestState, existingResponseState) {
            case (.previousError, _), (_, .previousError):
                // we previously hit an error, so we refuse to do anything now
                self = .init(requestState: existingRequestState, responseState: existingResponseState)
                return .previousError
            case (.idle, _):
                // This should be headers
                switch frame {
                case .headers:
                    self = .init(requestState: .headersProcessed, responseState: existingResponseState)
                    return .forwardFrame(frame)
                case .cancelPush, .goaway, .maxPushID, .settings, .pushPromise, .data:
                    self = .init(requestState: .previousError, responseState: existingResponseState)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Expected headers, got \(frame.type)",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: .here()
                        )
                    )
                }
            case (.headersProcessed, _):
                // This should be data or trailers
                switch frame {
                case .headers:
                    // these are the trailers
                    self = .init(requestState: .trailersProcessed, responseState: existingResponseState)
                    return .forwardFrame(frame)
                case .data:
                    // This is the body. State stays as-is, we can have any number of data frames
                    self = .init(requestState: existingRequestState, responseState: existingResponseState)
                    return .forwardFrame(frame)
                case .cancelPush, .goaway, .maxPushID, .settings, .pushPromise:
                    // Any other frame is an error
                    self = .init(requestState: .previousError, responseState: existingResponseState)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Expected headers or data, got \(frame.type)",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: .here()
                        )
                    )
                }
            case (.trailersProcessed, _):
                switch frame {
                case .cancelPush, .goaway, .maxPushID, .settings, .pushPromise, .data, .headers:
                    // We already got request trailers, so nothing more can go in the request now
                    self = .init(requestState: .previousError, responseState: existingResponseState)
                    return .emitConnectionError(
                        HTTP3Error(
                            code: .unexpectedFrame,
                            message: "Expected no further frames after request trailers, got \(frame.type)",
                            cause: nil,
                            errorCode: .H3_FRAME_UNEXPECTED,
                            location: .here()
                        )
                    )
                }
            }
        }
    }

    package struct ServerRequestStreamValidator: ~Copyable {
        private var underlying = RequestStreamValidator()

        package mutating func processInboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            self.underlying.processRequestFrame(frame)
        }

        package mutating func processOutboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            self.underlying.processResponseFrame(frame)
        }
    }

    package struct ClientRequestStreamValidator: ~Copyable {
        private var underlying = RequestStreamValidator()

        package mutating func processInboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            self.underlying.processResponseFrame(frame)
        }

        package mutating func processOutboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            self.underlying.processRequestFrame(frame)
        }
    }

    /// Checks that incoming frames are in the right order for a control stream, and that there are no outgoing frames.
    package struct IncomingControlStreamValidator: ~Copyable {
        private var sequenceValidator = ControlStreamSequenceValidator()

        package mutating func processInboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            // The only thing to check is the ordering, we don't need to do anything more than the sequence validator
            self.sequenceValidator.processNextFrame(frame)
        }

        package mutating func processOutboundFrame(_: HTTP3Frame) -> ProcessFrameAction {
            .emitConnectionError(
                HTTP3Error(
                    code: .invalidStream,
                    message: "Tried to write on an incoming unidirectional control stream",
                    cause: nil,
                    errorCode: nil,
                    location: .here()
                )
            )
        }

        package mutating func processInboundUnknownFrame() -> UnknownFrameAction {
            self.sequenceValidator.processUnknownFrame()
        }
    }

    /// Checks that outgoing frames are in the right order for a control stream, and there are no incoming frames.
    package struct OutgoingControlStreamValidator: ~Copyable {
        private var sequenceValidator = ControlStreamSequenceValidator()

        package mutating func processInboundFrame(_: HTTP3Frame) -> ProcessFrameAction {
            .emitConnectionError(
                HTTP3Error(
                    code: .invalidStream,
                    message: "Tried to read on an outgoing unidirectional control stream",
                    cause: nil,
                    errorCode: nil,
                    location: .here()
                )
            )
        }

        package mutating func processOutboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            // The only thing to check is the ordering, we don't need to do anything more than the sequence validator
            self.sequenceValidator.processNextFrame(frame)
        }

        package mutating func processInboundUnknownFrame() -> UnknownFrameAction {
            .emitConnectionError(
                HTTP3Error(
                    code: .invalidStream,
                    message: "Tried to read on an outgoing unidirectional control stream",
                    cause: nil,
                    errorCode: nil,
                    location: .here()
                )
            )
        }
    }

    /// Checks that incoming frames are in the right order for a push stream, and there are no outgoing frames.
    package struct IncomingPushStreamValidator: ~Copyable {
        private var sequenceValidator = PushStreamSequenceValidator()

        package mutating func processInboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            // The only thing to check is the ordering, we don't need to do anything more than the sequence validator
            self.sequenceValidator.processNextFrame(frame)
        }

        package mutating func processOutboundFrame(_: HTTP3Frame) -> ProcessFrameAction {
            .emitConnectionError(
                HTTP3Error(
                    code: .invalidStream,
                    message: "Tried to write on an incoming unidirectional push stream",
                    cause: nil,
                    errorCode: nil,
                    location: .here()
                )
            )
        }
    }

    /// Checks that outgoing frames are in the right order for a push stream, and there are no incoming frames.
    package struct OutgoingPushStreamValidator: ~Copyable {
        private var sequenceValidator = PushStreamSequenceValidator()

        package mutating func processInboundFrame(_: HTTP3Frame) -> ProcessFrameAction {
            .emitConnectionError(
                HTTP3Error(
                    code: .invalidStream,
                    message: "Tried to read on an outgoing unidirectional push stream",
                    cause: nil,
                    errorCode: nil,
                    location: .here()
                )
            )
        }

        package mutating func processOutboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
            // The only thing to check is the ordering, we don't need to do anything more than the sequence validator
            self.sequenceValidator.processNextFrame(frame)
        }
    }

    package init(streamType: HTTP3StreamType.Framed, incoming: Bool) {
        switch (streamType, incoming) {
        case (.control, true): self = .incomingControlStream(.init())
        case (.request, true): self = .incomingRequestStream(.init())
        case (.push, true): self = .incomingPushStream(.init())
        case (.control, false): self = .outgoingControlStream(.init())
        case (.request, false): self = .outgoingRequestStream(.init())
        case (.push, false): self = .outgoingPushStream(.init())
        }
    }

    package enum ProcessFrameAction {
        case forwardFrame(HTTP3Frame)
        case emitConnectionError(HTTP3Error)
        case emitStreamError(HTTP3Error)
        case previousError
    }

    package mutating func processInboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
        switch consume self {
        case .incomingControlStream(var v):
            let result = v.processInboundFrame(frame)
            self = .incomingControlStream(v)
            return result
        case .outgoingControlStream(var v):
            let result = v.processInboundFrame(frame)
            self = .outgoingControlStream(v)
            return result
        case .incomingRequestStream(var v):
            let result = v.processInboundFrame(frame)
            self = .incomingRequestStream(v)
            return result
        case .outgoingRequestStream(var v):
            let result = v.processInboundFrame(frame)
            self = .outgoingRequestStream(v)
            return result
        case .incomingPushStream(var v):
            let result = v.processInboundFrame(frame)
            self = .incomingPushStream(v)
            return result
        case .outgoingPushStream(var v):
            let result = v.processInboundFrame(frame)
            self = .outgoingPushStream(v)
            return result
        }
    }

    package mutating func processOutboundFrame(_ frame: HTTP3Frame) -> ProcessFrameAction {
        switch consume self {
        case .incomingControlStream(var v):
            let result = v.processOutboundFrame(frame)
            self = .incomingControlStream(v)
            return result
        case .outgoingControlStream(var v):
            let result = v.processOutboundFrame(frame)
            self = .outgoingControlStream(v)
            return result
        case .incomingRequestStream(var v):
            let result = v.processOutboundFrame(frame)
            self = .incomingRequestStream(v)
            return result
        case .outgoingRequestStream(var v):
            let result = v.processOutboundFrame(frame)
            self = .outgoingRequestStream(v)
            return result
        case .incomingPushStream(var v):
            let result = v.processOutboundFrame(frame)
            self = .incomingPushStream(v)
            return result
        case .outgoingPushStream(var v):
            let result = v.processOutboundFrame(frame)
            self = .outgoingPushStream(v)
            return result
        }
    }

    package enum UnknownFrameAction {
        case dropFrame
        case emitConnectionError(HTTP3Error)
        case previousError
    }

    package mutating func processInboundUnknownFrame() -> UnknownFrameAction {
        // Only the control stream cares about unknown frames, the other streams can just drop it.
        switch consume self {
        case .incomingControlStream(var v):
            let result = v.processInboundUnknownFrame()
            self = .incomingControlStream(v)
            return result
        case .outgoingControlStream(var v):
            let result = v.processInboundUnknownFrame()
            self = .outgoingControlStream(v)
            return result
        case .incomingRequestStream(let v):
            self = .incomingRequestStream(v)
            return .dropFrame
        case .outgoingRequestStream(let v):
            self = .outgoingRequestStream(v)
            return .dropFrame
        case .incomingPushStream(let v):
            self = .incomingPushStream(v)
            return .dropFrame
        case .outgoingPushStream(let v):
            self = .outgoingPushStream(v)
            return .dropFrame
        }
    }
}

extension HTTP3Frame {
    package var type: HTTP3FrameType {
        switch self {
        case .headers: return .headers
        case .data: return .data
        case .cancelPush: return .cancelPush
        case .settings: return .settings
        case .goaway: return .goaway
        case .maxPushID: return .maxPushID
        case .pushPromise: return .pushPromise
        }
    }
}
