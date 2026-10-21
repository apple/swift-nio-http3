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

/// Processes and validates the contents of HTTP/3 frames into the parts of an HTTP message.
@available(anyAppleOS 27, *)
protocol HTTPMessagePartProcessor {
    associatedtype Part

    func head(fields: [HTTPField]) throws(HTTP3Error) -> Part
    func body(buffer: ByteBuffer) -> Part
    func end(trailers: [HTTPField]) throws(HTTP3Error) -> Part
    func end() -> Part
}

/// Processes and validates the parts of a request, as received by a server.
@available(anyAppleOS 27, *)
struct HTTPRequestPartProcessor: HTTPMessagePartProcessor {
    /// Whether we can accept Extended CONNECT requests, i.e. if we sent `SETTINGS_ENABLE_CONNECT_PROTOCOL` with value 1.
    let extendedConnectSupported: Bool

    init(extendedConnectSupported: Bool = false) {
        self.extendedConnectSupported = extendedConnectSupported
    }

    func head(fields: [HTTPField]) throws(HTTP3Error) -> HTTPRequestPart {
        .head(
            try HTTP3MessageDecoding.request(fields: fields, extendedConnectSupported: self.extendedConnectSupported)
        )
    }

    func body(buffer: ByteBuffer) -> HTTPRequestPart {
        .body(buffer)
    }

    func end(trailers: [HTTPField]) throws(HTTP3Error) -> HTTPRequestPart {
        .end(try HTTP3MessageDecoding.trailers(fields: trailers))
    }

    func end() -> HTTPRequestPart {
        .end(nil)
    }
}

/// Processes and validates the parts of a response, as received by a server.
@available(anyAppleOS 27, *)
struct HTTPResponsePartProcessor: HTTPMessagePartProcessor {
    func head(fields: [HTTPField]) throws(HTTP3Error) -> HTTPResponsePart {
        .head(try HTTP3MessageDecoding.response(fields: fields))
    }

    func body(buffer: ByteBuffer) -> HTTPResponsePart {
        .body(buffer)
    }

    func end(trailers: [HTTPField]) throws(HTTP3Error) -> HTTPResponsePart {
        .end(try HTTP3MessageDecoding.trailers(fields: trailers))
    }

    func end() -> HTTPResponsePart {
        .end(nil)
    }
}

/// Process HTTP3Frames into HTTPMessageParts.
/// Use this to convert incoming frames into message parts.
@available(anyAppleOS 27, *)
struct HTTPMessageParsingStateMachine<Processor: HTTPMessagePartProcessor> {
    typealias Part = Processor.Part

    enum State {
        case awaitingHeaders
        case awaitingBodyOrTrailers
        case messageComplete
        case failed
    }

    private var state = State.awaitingHeaders

    /// Processes and validates the parts of the message.
    private let processor: Processor

    init(_ processor: Processor) {
        self.processor = processor
    }

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
                    let part = try self.processor.head(fields: headers.fields)
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
                    let part = try self.processor.end(trailers: headers.fields)
                    self.state = .messageComplete
                    return .returnPart(part)
                } catch {
                    self.state = .failed
                    return .emitError(error)
                }
            // Any number of data frames is fine. State stays as-is
            case .data(let payload):
                return .returnPart(self.processor.body(buffer: payload.payload))
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
            return .returnPart(self.processor.end())
        case .failed:
            return .none
        case .messageComplete:
            // If we processed trailers, that means we sent an end, so don't send another one
            return .none
        }
    }
}

/// Use this on clients to write `HTTPRequestPart` and receive `HTTPResponsePart`.
@available(anyAppleOS 27, *)
public final class HTTP3ToHTTPClientCodec: ChannelDuplexHandler {
    public typealias InboundIn = HTTP3Frame
    public typealias InboundOut = HTTPResponsePart

    public typealias OutboundIn = HTTPRequestPart
    public typealias OutboundOut = HTTP3Frame

    private var readState = HTTPMessageParsingStateMachine(HTTPResponsePartProcessor())

    /// Whether the server sent `SETTINGS_ENABLE_CONNECT_PROTOCOL` with value 1, i.e. whether it accepts Extended
    /// CONNECT requests (RFC 9220 § 3).
    private var extendedConnectSupported: Bool

    /// - Parameter extendedConnectSupported: Whether the server sent `SETTINGS_ENABLE_CONNECT_PROTOCOL` with value 1,
    ///   i.e. whether it accepts Extended CONNECT requests (RFC 9220 § 3).
    ///
    ///   Set to `false` if the server's SETTINGS frame hasn't arrived yet (the ``ReceivedSettings`` inbound event will
    ///   fire when the server's SETTINGS arrive, and the flag will automatically be updated then).
    public init(extendedConnectSupported: Bool = false) {
        self.extendedConnectSupported = extendedConnectSupported
    }

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
            if request.extendedConnectProtocol != nil {
                // The :protocol pseudo-header is only allowed on CONNECT requests.
                guard request.method == .connect else {
                    let error = HTTP3Error(
                        code: .malformedMessage,
                        message: ":protocol pseudo-header is only allowed on CONNECT requests",
                        cause: nil,
                        errorCode: nil,
                        location: .here()
                    )
                    context.fireErrorCaught(error)
                    promise?.fail(error)

                    return
                }

                // A client MUST NOT send an Extended CONNECT request unless it has received
                // SETTINGS_ENABLE_CONNECT_PROTOCOL with value 1 from the server (RFC 9220 § 3).
                guard self.extendedConnectSupported else {
                    let error = HTTP3Error(
                        code: .extendedConnectNotEnabled,
                        message: "The server has not enabled Extended CONNECT (SETTINGS_ENABLE_CONNECT_PROTOCOL)",
                        cause: nil,
                        errorCode: nil,
                        location: .here()
                    )
                    context.fireErrorCaught(error)
                    promise?.fail(error)

                    return
                }
            }

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
        if let settings = event as? ReceivedSettings {
            self.extendedConnectSupported = settings.extendedConnectSupported
            return
        }

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
@available(anyAppleOS 27, *)
public final class HTTP3ToHTTPServerCodec: ChannelDuplexHandler {
    public typealias InboundIn = HTTP3Frame
    public typealias InboundOut = HTTPRequestPart

    public typealias OutboundIn = HTTPResponsePart
    public typealias OutboundOut = HTTP3Frame

    private var readState: HTTPMessageParsingStateMachine<HTTPRequestPartProcessor>

    /// Create a new ``HTTP3ToHTTPServerCodec``.
    ///
    /// - Parameter extendedConnectSupported: Whether Extended CONNECT requests are accepted. This must match the
    ///   `SETTINGS_ENABLE_CONNECT_PROTOCOL` value sent to the peer. If `false`, incoming Extended CONNECT requests will
    ///   result in a malformed message error per RFC 8441 § 3.
    public init(extendedConnectSupported: Bool = false) {
        self.readState = .init(HTTPRequestPartProcessor(extendedConnectSupported: extendedConnectSupported))
    }

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
