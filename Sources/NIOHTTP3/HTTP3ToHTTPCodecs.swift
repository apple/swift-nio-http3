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

@_spi(PackageInternal) public import HTTP3
import HTTPTypes
public import NIOCore
public import NIOHTTPTypes

protocol HTTPMessagePart {
    static func head(fields: [HTTPField]) throws(HTTP3Error) -> Self
    static func body(buffer: ByteBuffer) -> Self
    static func end(trailers: [HTTPField]) throws(HTTP3Error) -> Self
    static func end() -> Self
}

extension HTTPRequestPart: HTTPMessagePart {
    static func head(fields: [HTTPField]) throws(HTTP3Error) -> HTTPRequestPart {
        .head(try HTTP3MessageValidation.request(fields: fields))
    }

    static func body(buffer: ByteBuffer) -> HTTPRequestPart {
        .body(buffer)
    }

    static func end(trailers: [HTTPField]) throws(HTTP3Error) -> HTTPRequestPart {
        .end(try HTTP3MessageValidation.trailers(fields: trailers))
    }

    static func end() -> HTTPRequestPart {
        .end(nil)
    }
}

extension HTTPResponsePart: HTTPMessagePart {
    static func head(fields: [HTTPField]) throws(HTTP3Error) -> HTTPResponsePart {
        .head(try HTTP3MessageValidation.response(fields: fields))
    }

    static func body(buffer: ByteBuffer) -> HTTPResponsePart {
        .body(buffer)
    }

    static func end(trailers: [HTTPField]) throws(HTTP3Error) -> HTTPResponsePart {
        .end(try HTTP3MessageValidation.trailers(fields: trailers))
    }

    static func end() -> HTTPResponsePart {
        .end(nil)
    }
}

/// Process HTTP3Frames into HTTPMessageParts.
/// Use this to convert incoming frames into message parts.
struct HTTPMessageParsingStateMachine<Part: HTTPMessagePart> {
    enum State {
        case awaitingHeaders
        case awaitingBodyOrTrailers
        case messageComplete
        case failed
    }

    private var state = State.awaitingHeaders

    init() {}

    enum ProcessFrameAction {
        case returnPart(Part)
        case emitError(HTTP3Error)
    }

    mutating func processFrame(frame: HTTP3Frame) -> ProcessFrameAction? {
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

    enum InputClosedAction {
        case returnPart(Part)
    }

    mutating func inputClosed() -> InputClosedAction? {
        switch self.state {
        case .awaitingHeaders:
            // The input was closed without even receiving a head part. This case is handled appropriately by
            // ``HTTP3StreamHandler``, so just return `.none` here.
            self.state = .failed
            return .none
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
        case .none:
            break
        }

        context.fireUserInboundEventTriggered(event)
    }
}

@available(*, unavailable)
extension HTTP3ToHTTPServerCodec: Sendable {}
