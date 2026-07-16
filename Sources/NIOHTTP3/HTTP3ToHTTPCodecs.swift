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

public import HTTP3
package import HTTPTypes
public import NIOCore
public import NIOHTTPTypes
internal import NIOQUICHelpers

package protocol HTTPMessagePart {
    static func head(fields: [HTTPField]) throws(HTTP3Error) -> Self
    static func body(buffer: ByteBuffer) -> Self
    static func end(trailers: [HTTPField]) throws(HTTP3Error) -> Self
    static func end() -> Self
}

struct HTTP3FieldError: Error, CustomStringConvertible {
    let description: String
}

private func invalidHeadersError(message: String, location: HTTP3Error.SourceLocation) -> HTTP3Error {
    let cause = HTTP3FieldError(description: message)
    return HTTP3Error(
        code: .malformedMessage,
        message: "Invalid headers",
        cause: cause,
        errorCode: .H3_MESSAGE_ERROR,
        location: location
    )
}

extension HTTPRequestPart: HTTPMessagePart {
    package static func head(fields: [HTTPField]) throws(HTTP3Error) -> HTTPRequestPart {
        let request: HTTPRequest
        do {
            request = try HTTPRequest(parsed: fields)
        } catch {
            throw HTTP3Error(
                code: .malformedMessage,
                message: "Invalid headers",
                cause: error,
                errorCode: .H3_MESSAGE_ERROR,
                location: .here()
            )
        }
        if let te = request.headerFields[.te] {
            if te != "trailers" {
                throw invalidHeadersError(message: "te field must contain trailers if present", location: .here())
            }
        }
        if request.headerFields.contains(.transferEncoding) {
            throw invalidHeadersError(message: "transfer-encoding field must not be present", location: .here())
        }
        let scheme = request.scheme
        let path = request.path
        let authority = request.authority
        let host = request.headerFields[.init(parsed: "host")!]
        if request.method != .connect {
            // All HTTP/3 requests MUST include exactly one value for the :method, :scheme, and :path pseudo-header fields, unless the request is a CONNECT request
            guard let scheme else {
                throw invalidHeadersError(message: "Missing scheme", location: .here())
            }
            guard let path else {
                throw invalidHeadersError(message: "Missing path", location: .here())
            }
            // If the :scheme pseudo-header field identifies a scheme that has a mandatory authority component (including "http" and "https"), the request MUST contain either an :authority pseudo-header field or a Host header field
            if scheme == "https" || scheme == "http" {
                guard host != nil || authority != nil else {
                    throw invalidHeadersError(message: "Missing host and authority", location: .here())
                }
            }
            // If these fields are present, they MUST NOT be empty
            if let host, host.isEmpty {
                throw invalidHeadersError(message: "host field is empty", location: .here())
            }
            if let authority, authority.isEmpty {
                throw invalidHeadersError(message: "authority field is empty", location: .here())
            }
            // If both fields are present, they MUST contain the same value
            if let host, let authority {
                guard host == authority else {
                    throw invalidHeadersError(message: "Mismatched authority and host", location: .here())
                }
            }

            // The path pseudo-header field MUST NOT be empty for "http" or "https" URIs
            if scheme == "https" || scheme == "http" {
                guard !path.isEmpty else {
                    throw invalidHeadersError(message: "Path field is empty", location: .here())
                }
            }
        } else {
            // A CONNECT request MUST be constructed as follows:
            // - The :method pseudo-header field is set to "CONNECT"
            // - The :scheme and :path pseudo-header fields are omitted
            // - TODO: The :authority pseudo-header field contains the host and port to connect to (equivalent to the authority-form of the request-target of CONNECT requests; see Section 7.1 of [HTTP]).
            guard scheme == nil && path == nil else {
                throw invalidHeadersError(message: "CONNECT request must not contain path or scheme", location: .here())
            }
            guard authority != nil else {
                throw invalidHeadersError(message: "CONNECT request must contain authority", location: .here())
            }
        }

        return .head(request)
    }

    package static func body(buffer: ByteBuffer) -> HTTPRequestPart {
        .body(buffer)
    }

    package static func end(trailers: [HTTPField]) throws(HTTP3Error) -> HTTPRequestPart {
        if trailers.isEmpty {
            return .end(nil)
        } else {
            do {
                return try .end(HTTPFields(parsedTrailerFields: trailers))
            } catch {
                throw HTTP3Error(
                    code: .malformedMessage,
                    message: "Invalid trailers",
                    cause: error,
                    errorCode: .H3_MESSAGE_ERROR,
                    location: .here()
                )
            }
        }
    }

    package static func end() -> HTTPRequestPart {
        .end(nil)
    }
}

extension HTTPResponsePart: HTTPMessagePart {
    package static func head(fields: [HTTPField]) throws(HTTP3Error) -> HTTPResponsePart {
        let response: HTTPResponse
        do {
            response = try HTTPResponse(parsed: fields)
        } catch {
            throw HTTP3Error(
                code: .malformedMessage,
                message: "Invalid headers",
                cause: error,
                errorCode: .H3_MESSAGE_ERROR,
                location: .here()
            )
        }
        if response.headerFields.contains(.te) {
            throw invalidHeadersError(message: "te field must not be present", location: .here())
        }
        if response.headerFields.contains(.transferEncoding) {
            throw invalidHeadersError(message: "transfer-encoding field must not be present", location: .here())
        }
        return .head(response)
    }

    package static func body(buffer: ByteBuffer) -> HTTPResponsePart {
        .body(buffer)
    }

    package static func end(trailers: [HTTPField]) throws(HTTP3Error) -> HTTPResponsePart {
        if trailers.isEmpty {
            return .end(nil)
        } else {
            do {
                return try .end(HTTPFields(parsedTrailerFields: trailers))
            } catch {
                throw HTTP3Error(
                    code: .malformedMessage,
                    message: "Invalid trailers",
                    cause: error,
                    errorCode: .H3_MESSAGE_ERROR,
                    location: .here()
                )
            }
        }
    }

    package static func end() -> HTTPResponsePart {
        .end(nil)
    }
}

/// Process HTTP3Frames into HTTPMessageParts.
/// Use this to convert incoming frames into message parts.
package struct HTTPMessageParsingStateMachine<Part: HTTPMessagePart> {
    enum State {
        case awaitingHeaders
        case awaitingBodyOrTrailers
        case messageComplete
        case failed
    }

    private var state = State.awaitingHeaders

    package init() {}

    package enum ProcessFrameAction {
        case returnPart(Part)
        case emitError(HTTP3Error)
    }

    package mutating func processFrame(frame: HTTP3Frame) -> ProcessFrameAction? {
        switch self.state {
        case .failed:
            return .none
        case .awaitingHeaders:
            switch frame {
            case .headers(let headers):
                do {
                    let part = try Part.head(fields: headers.fields)
                    if headers.representsInterimResponse {
                        // Multiple interim (1xx) responses can precede the final response; remain in the same state to
                        // accept further interim responses or the final response. We can only reach this branch on the
                        // response parsing side.
                        self.state = .awaitingHeaders
                    } else {
                        self.state = .awaitingBodyOrTrailers
                    }
                    return .returnPart(part)
                } catch {
                    self.state = .failed
                    return .emitError(error)
                }
            case .data, .cancelPush, .settings, .maxPushID, .pushPromise, .goaway:
                // This should not happen because the stream state machine shouldn't allow a bad frame to get here
                fatalError("Unexpected frame")
            }
        case .awaitingBodyOrTrailers:
            switch frame {
            case .headers(let headers):
                // If the incoming frame is of type 'headers', it must be the trailers
                do {
                    let part = try Part.end(trailers: headers.fields)
                    self.state = .messageComplete
                    return .returnPart(part)
                } catch {
                    self.state = .failed
                    return .emitError(error)
                }
            // Any number of data frames is fine. State stays as-is
            case .data(let payload):
                return .returnPart(.body(buffer: payload.payload))
            case .cancelPush, .settings, .maxPushID, .pushPromise, .goaway:
                // This should not happen because the stream state machine shouldn't allow a bad frame to get here
                fatalError("Unexpected frame")
            }
        case .messageComplete:
            // This should not happen because the stream state machine shouldn't allow a bad frame to get here
            fatalError("More frames received after trailers")
        }
    }

    package enum InputClosedAction {
        case returnPart(Part)
        case notifyMessageIncomplete
    }

    package mutating func inputClosed() -> InputClosedAction? {
        switch self.state {
        case .awaitingHeaders:
            // Either no request/response head was received at all, or, in the case of clients, only interim response
            // heads were received. In either case, the message is incomplete.
            self.state = .failed
            return .notifyMessageIncomplete
        case .awaitingBodyOrTrailers:
            self.state = .messageComplete
            return .returnPart(.end())
        case .failed:
            return .none
        case .messageComplete:
            // If we processed trailers, that means we sent an end, so don't send another one
            return .none
        }
    }
}

/// Use this on clients to write `HTTPRequestPart` and receive `HTTPResponsePart`.
public final class HTTP3ToHTTPClientCodec: ChannelDuplexHandler {
    public typealias InboundIn = HTTP3Frame
    public typealias InboundOut = HTTPResponsePart

    public typealias OutboundIn = HTTPRequestPart
    public typealias OutboundOut = HTTP3Frame

    private var readState: HTTPMessageParsingStateMachine<HTTPResponsePart> = .init()

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        let action = self.readState.processFrame(frame: frame)
        switch action {
        case .returnPart(let part):
            context.fireChannelRead(wrapInboundOut(part))
        case .emitError(let error):
            context.fireErrorCaught(error)
        case .none:
            break
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)

        switch part {
        case .head(let request):
            var fields = [HTTPField]()
            fields.reserveCapacity(request.headerFields.count + 5)
            fields.append(request.pseudoHeaderFields.method)
            if let scheme = request.pseudoHeaderFields.scheme {
                fields.append(scheme)
            }
            if let authority = request.pseudoHeaderFields.authority {
                fields.append(authority)
            }
            if let path = request.pseudoHeaderFields.path {
                fields.append(path)
            }
            if let extendedConnectProtocol = request.pseudoHeaderFields.extendedConnectProtocol {
                fields.append(extendedConnectProtocol)
            }
            for field in request.headerFields {
                fields.append(field)
            }
            let frame = HTTP3Frame.headers(fields)
            context.write(wrapOutboundOut(frame), promise: promise)
        case .body(let data):
            let frame = HTTP3Frame.data(data)
            context.write(wrapOutboundOut(frame), promise: promise)
        case .end(let trailers):
            if let trailers {
                var fields = [HTTPField]()
                fields.reserveCapacity(trailers.count)
                for field in trailers {
                    fields.append(field)
                }
                let frame = HTTP3Frame.headers(fields)
                context.write(wrapOutboundOut(frame), promise: nil)
                context.close(mode: .output, promise: promise)
            } else {
                // No trailers, just close
                context.close(mode: .output, promise: promise)
            }
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event as? ChannelEvent == ChannelEvent.inputClosed else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        let action = self.readState.inputClosed()
        switch action {
        case .returnPart(let part):
            context.fireChannelRead(self.wrapInboundOut(part))
            context.fireChannelReadComplete()
        case .notifyMessageIncomplete:
            // Inform the downstream application about this.
            // See https://datatracker.ietf.org/doc/html/rfc9114#section-4.1.1-6.
            context.fireErrorCaught(
                HTTP3Error(
                    code: .peerTerminatedStream,
                    message: "Stream closed before a complete response was received",
                    cause: nil,
                    errorCode: .H3_NO_ERROR,
                    location: .here()
                )
            )
        case .none:
            break
        }

        context.fireUserInboundEventTriggered(event)
    }
}

@available(*, unavailable)
extension HTTP3ToHTTPClientCodec: Sendable {}

/// Use this on servers to receive `HTTPRequestPart` and write `HTTPResponsePart`.
public final class HTTP3ToHTTPServerCodec: ChannelDuplexHandler {
    public typealias InboundIn = HTTP3Frame
    public typealias InboundOut = HTTPRequestPart

    public typealias OutboundIn = HTTPResponsePart
    public typealias OutboundOut = HTTP3Frame

    private var readState: HTTPMessageParsingStateMachine<HTTPRequestPart> = .init()

    /// Whether a complete response has been written.
    private var completedResponse = false

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        let action = self.readState.processFrame(frame: frame)
        switch action {
        case .returnPart(let part):
            context.fireChannelRead(wrapInboundOut(part))
        case .emitError(let error):
            context.fireErrorCaught(error)
        case .none:
            break
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)
        switch part {
        case .head(let request):
            var fields = [HTTPField]()
            fields.reserveCapacity(request.headerFields.count + 1)
            fields.append(request.pseudoHeaderFields.status)
            for field in request.headerFields {
                fields.append(field)
            }
            let frame = HTTP3Frame.headers(fields)
            context.write(wrapOutboundOut(frame), promise: promise)
        case .body(let data):
            let frame = HTTP3Frame.data(data)
            context.write(wrapOutboundOut(frame), promise: promise)
        case .end(let trailers):
            if let trailers {
                var fields = [HTTPField]()
                fields.reserveCapacity(trailers.count)
                for field in trailers {
                    fields.append(field)
                }
                let frame = HTTP3Frame.headers(fields)
                context.write(wrapOutboundOut(frame), promise: nil)
                context.close(mode: .output, promise: promise)
            } else {
                // No trailers, just close
                context.close(mode: .output, promise: promise)
            }

            self.completedResponse = true
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event as? ChannelEvent == ChannelEvent.inputClosed else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        let action = self.readState.inputClosed()
        switch action {
        case .returnPart(let part):
            context.fireChannelRead(self.wrapInboundOut(part))
            context.fireChannelReadComplete()
        case .notifyMessageIncomplete:
            // The client terminated the stream before delivering a complete request. Per RFC 9114 § 4.1, the server
            // should abort the response stream with H3_REQUEST_INCOMPLETE (unless a complete response was already
            // written).
            if self.completedResponse { break }

            context.triggerUserOutboundEvent(
                QUICResetStreamEvent(code: QUICApplicationErrorCode(.H3_REQUEST_INCOMPLETE)),
                promise: nil
            )
            // Inform the downstream application about this.
            context.fireErrorCaught(
                HTTP3Error(
                    code: .peerTerminatedStream,
                    message: "Stream closed before a complete request was received",
                    cause: nil,
                    errorCode: .H3_REQUEST_INCOMPLETE,
                    location: .here()
                )
            )
        case .none:
            break
        }

        context.fireUserInboundEventTriggered(event)
    }
}

@available(*, unavailable)
extension HTTP3ToHTTPServerCodec: Sendable {}
