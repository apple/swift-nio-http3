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
protocol HTTPMessagePartProcessor {
    associatedtype Part

    func head(fields: [HTTPField]) throws(HTTP3Error) -> Part
    func body(buffer: ByteBuffer) -> Part
    func end(trailers: [HTTPField]) throws(HTTP3Error) -> Part
    func end() -> Part
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
        errorCode: .messageError,
        location: location
    )
}

/// Processes and validates the parts of a request, as received by a server.
struct HTTPRequestPartProcessor: HTTPMessagePartProcessor {
    /// Whether we can accept Extended CONNECT requests, i.e. if we sent `SETTINGS_ENABLE_CONNECT_PROTOCOL` with value 1.
    let isExtendedConnectEnabled: Bool

    private static func validateNonConnectRequest(_ request: HTTPRequest) throws(HTTP3Error) {
        precondition(request.method != .connect)

        let scheme = request.scheme
        let path = request.path
        let authority = request.authority
        let host = request.headerFields[.host]

        // All HTTP/3 requests MUST include exactly one value for the :method, :scheme, and :path pseudo-header fields,
        // unless the request is a CONNECT request
        guard let scheme else {
            throw invalidHeadersError(message: "Missing scheme", location: .here())
        }
        guard let path else {
            throw invalidHeadersError(message: "Missing path", location: .here())
        }
        // If the :scheme pseudo-header field identifies a scheme that has a mandatory authority component (including
        // "http" and "https"), the request MUST contain either an :authority pseudo-header field or a Host header
        // field.
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
    }

    private func validateConnectRequest(_ request: HTTPRequest) throws(HTTP3Error) {
        precondition(request.method == .connect)

        let scheme = request.scheme
        let path = request.path
        let authority = request.authority

        if request.extendedConnectProtocol != nil {
            // This request contains a :protocol pseudo-header. As such, the rules of RFC 8441 §4 apply.
            guard scheme != nil, path != nil else {
                throw invalidHeadersError(
                    message: "CONNECT request with a :protocol pseudo-header must contain path and scheme",
                    location: .here()
                )
            }

            // A client MUST NOT send an Extended CONNECT request unless we sent SETTINGS_ENABLE_CONNECT_PROTOCOL
            // with a value of 1 (RFC 8441 § 3).
            guard self.isExtendedConnectEnabled else {
                throw HTTP3Error(
                    code: .extendedConnectNotEnabled,
                    message: "Extended CONNECT request received, but SETTINGS_ENABLE_CONNECT_PROTOCOL was not sent",
                    cause: nil,
                    errorCode: .messageError,
                    location: .here()
                )
            }
        } else {
            // A CONNECT request MUST be constructed as follows:

            // 1. The :scheme and :path pseudo-header fields are omitted
            guard scheme == nil && path == nil else {
                throw invalidHeadersError(message: "CONNECT request must not contain path or scheme", location: .here())
            }

            // 2. The :authority pseudo-header field contains the host and port to connect to (equivalent to the
            //   authority-form of the request-target of CONNECT requests; see Section 7.1 of [HTTP]).
            guard let authority else {
                throw invalidHeadersError(message: "CONNECT request must contain authority", location: .here())
            }

            guard Self.isValidConnectAuthority(authority) else {
                throw invalidHeadersError(message: "Invalid :authority pseudo-header value", location: .here())
            }
        }
    }

    /// Whether `authority` is in authority-form, `uri-host ":" port` (RFC 9110 § 7.1).
    private static func isValidConnectAuthority(_ authority: String) -> Bool {
        let utf8 = authority.utf8
        let hostEnd: String.UTF8View.Index

        if utf8.first == UInt8(ascii: "[") {
            // IP-literal: must be an IPv6 address.
            guard let close = utf8.firstIndex(of: UInt8(ascii: "]")) else {
                return false
            }

            let host = authority[utf8.index(after: utf8.startIndex)..<close]
            // IPv6 Zone IDs are not supported.
            guard !host.utf8.contains(UInt8(ascii: "%")) else {
                return false
            }
            // Check if `host` is a valid IPv6 address.
            guard case .v6 = try? SocketAddress(ipAddress: String(host), port: 0) else {
                return false
            }
            hostEnd = utf8.index(after: close)
        } else {
            // IPv4address or reg-name.
            guard let colon = utf8.firstIndex(of: UInt8(ascii: ":")) else {
                return false
            }

            let host = utf8[..<colon]
            guard !host.isEmpty, host.allSatisfy(Self.isRegNameByte) else {
                return false
            }
            hostEnd = colon
        }

        // Check that there is something after the ":".
        guard hostEnd < utf8.endIndex, utf8[hostEnd] == UInt8(ascii: ":") else {
            return false
        }
        let port = utf8[utf8.index(after: hostEnd)...]

        guard port.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let portInt = Int(Substring(port))
        else {
            return false
        }

        return portInt <= 65535
    }

    /// Whether the provided byte is a valid `reg-name` byte (see RFC 3986, Appendix A).
    private static func isRegNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true

        case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"),  // unreserved
            UInt8(ascii: "%"),  // pct-encoded
            UInt8(ascii: "!"), UInt8(ascii: "$"), UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "("),
            UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: ","), UInt8(ascii: ";"),
            UInt8(ascii: "="):  // sub-delims
            return true

        default:
            return false
        }
    }

    func head(fields: [HTTPField]) throws(HTTP3Error) -> HTTPRequestPart {
        let request: HTTPRequest
        do {
            request = try HTTPRequest(parsed: fields)
        } catch {
            throw HTTP3Error(
                code: .malformedMessage,
                message: "Invalid headers",
                cause: error,
                errorCode: .messageError,
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

        if request.method == .connect {
            try self.validateConnectRequest(request)
        } else {
            try Self.validateNonConnectRequest(request)
        }

        return .head(request)
    }

    func body(buffer: ByteBuffer) -> HTTPRequestPart {
        .body(buffer)
    }

    func end(trailers: [HTTPField]) throws(HTTP3Error) -> HTTPRequestPart {
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
                    errorCode: .messageError,
                    location: .here()
                )
            }
        }
    }

    func end() -> HTTPRequestPart {
        .end(nil)
    }
}

/// Parses the parts of a response, as received by a client.
struct HTTPResponsePartProcessor: HTTPMessagePartProcessor {
    func head(fields: [HTTPField]) throws(HTTP3Error) -> HTTPResponsePart {
        let response: HTTPResponse
        do {
            response = try HTTPResponse(parsed: fields)
        } catch {
            throw HTTP3Error(
                code: .malformedMessage,
                message: "Invalid headers",
                cause: error,
                errorCode: .messageError,
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

    func body(buffer: ByteBuffer) -> HTTPResponsePart {
        .body(buffer)
    }

    func end(trailers: [HTTPField]) throws(HTTP3Error) -> HTTPResponsePart {
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
                    errorCode: .messageError,
                    location: .here()
                )
            }
        }
    }

    func end() -> HTTPResponsePart {
        .end(nil)
    }
}

/// Process HTTP3Frames into HTTPMessageParts.
/// Use this to convert incoming frames into message parts.
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
public final class HTTP3ToHTTPClientCodec: ChannelDuplexHandler {
    public typealias InboundIn = HTTP3Frame
    public typealias InboundOut = HTTPResponsePart

    public typealias OutboundIn = HTTPRequestPart
    public typealias OutboundOut = HTTP3Frame

    private var readState = HTTPMessageParsingStateMachine(HTTPResponsePartProcessor())

    /// Whether the server sent `SETTINGS_ENABLE_CONNECT_PROTOCOL` with value 1, i.e. whether it accepts Extended
    /// CONNECT requests (RFC 9220 § 3). We start with `false` and update this once the server's SETTINGS have arrived.
    private var isExtendedConnectEnabled = false

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
            // A client MUST NOT send an Extended CONNECT request unless it has received
            // SETTINGS_ENABLE_CONNECT_PROTOCOL with value 1 from the server (RFC 9220 § 3).
            if request.method == .connect, request.extendedConnectProtocol != nil && !self.isExtendedConnectEnabled {
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
            self.isExtendedConnectEnabled = settings.extendedConnectSupported
            context.fireUserInboundEventTriggered(event)
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
public final class HTTP3ToHTTPServerCodec: ChannelDuplexHandler {
    public typealias InboundIn = HTTP3Frame
    public typealias InboundOut = HTTPRequestPart

    public typealias OutboundIn = HTTPResponsePart
    public typealias OutboundOut = HTTP3Frame

    private var readState: HTTPMessageParsingStateMachine<HTTPRequestPartProcessor>

    /// Create a new ``HTTP3ToHTTPServerCodec``.
    ///
    /// - Parameter isExtendedConnectEnabled: Whether Extended CONNECT requests are accepted. This must match the
    ///   `SETTINGS_ENABLE_CONNECT_PROTOCOL` value sent to the peer. If `false`, incoming Extended CONNECT requests will
    ///   result in a malformed message error per RFC 8441 § 3.
    public init(isExtendedConnectEnabled: Bool) {
        self.readState = .init(HTTPRequestPartProcessor(isExtendedConnectEnabled: isExtendedConnectEnabled))
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

extension HTTPField.Name {
    // `HTTPField.Name.host` is unavailable in HTTPTypes (it steers callers to `:authority`), but
    // RFC 9114 requires us to validate `Host` against `:authority`, so construct the name once.
    static let host = HTTPField.Name(parsed: "host")!
}
