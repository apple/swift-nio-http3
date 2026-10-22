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

public import HTTPTypes

import enum NIOCore.SocketAddress

/// Turns decoded field sections into HTTP messages, enforcing the rules RFC 9114 § 4.2 and § 4.3 place on them.
///
/// Every violation is a malformed message, which RFC 9114 § 4.1.2 requires to be treated as a stream error of type
/// H3_MESSAGE_ERROR.
@available(anyAppleOS 27, *)
@_spi(PackageInternal)
public enum HTTP3MessageDecoding {
    struct FieldError: Error, CustomStringConvertible {
        let description: String
    }

    @inline(never)
    private static func invalidHeadersError(message: String, location: HTTP3Error.SourceLocation) -> HTTP3Error {
        HTTP3Error(
            code: .malformedMessage,
            message: "Invalid headers",
            cause: FieldError(description: message),
            errorCode: .messageError,
            location: location
        )
    }

    @inline(never)
    private static func unparsableError(
        message: String,
        cause: any Error,
        location: HTTP3Error.SourceLocation
    ) -> HTTP3Error {
        HTTP3Error(
            code: .malformedMessage,
            message: message,
            cause: cause,
            errorCode: .messageError,
            location: location
        )
    }

    /// Builds a request from the fields of a request's HEADERS frame.
    @_spi(PackageInternal)
    public static func request(fields: [HTTPField], extendedConnectSupported: Bool) throws(HTTP3Error) -> HTTPRequest {
        let request: HTTPRequest
        do {
            request = try HTTPRequest(parsed: fields)
        } catch {
            throw Self.unparsableError(message: "Invalid headers", cause: error, location: .here())
        }
        if let te = request.headerFields[.te] {
            if te != "trailers" {
                throw Self.invalidHeadersError(
                    message: "te field must contain trailers if present",
                    location: .here()
                )
            }
        }
        if request.headerFields.contains(.transferEncoding) {
            throw Self.invalidHeadersError(message: "transfer-encoding field must not be present", location: .here())
        }
        if request.method == .connect {
            try Self.validateConnectRequest(request, extendedConnectSupported: extendedConnectSupported)
        } else {
            try Self.validateNonConnectRequest(request)
        }

        return request
    }

    private static func validateNonConnectRequest(_ request: HTTPRequest) throws(HTTP3Error) {
        precondition(request.method != .connect)

        let scheme = request.scheme
        let path = request.path
        let authority = request.authority
        let host = request.headerFields[.host]

        // The :protocol pseudo-header is only allowed on CONNECT requests.
        if request.extendedConnectProtocol != nil {
            throw Self.invalidHeadersError(
                message: ":protocol pseudo-header is only allowed on CONNECT requests",
                location: .here()
            )
        }

        // All HTTP/3 requests MUST include exactly one value for the :method, :scheme, and :path pseudo-header fields,
        // unless the request is a CONNECT request
        guard let scheme else {
            throw Self.invalidHeadersError(message: "Missing scheme", location: .here())
        }
        guard let path else {
            throw Self.invalidHeadersError(message: "Missing path", location: .here())
        }
        // If the :scheme pseudo-header field identifies a scheme that has a mandatory authority component (including
        // "http" and "https"), the request MUST contain either an :authority pseudo-header field or a Host header
        // field.
        if scheme == "https" || scheme == "http" {
            guard host != nil || authority != nil else {
                throw Self.invalidHeadersError(message: "Missing host and authority", location: .here())
            }
        }
        // If these fields are present, they MUST NOT be empty
        if let host, host.isEmpty {
            throw Self.invalidHeadersError(message: "host field is empty", location: .here())
        }
        if let authority, authority.isEmpty {
            throw Self.invalidHeadersError(message: "authority field is empty", location: .here())
        }
        // If both fields are present, they MUST contain the same value
        if let host, let authority {
            guard host == authority else {
                throw Self.invalidHeadersError(message: "Mismatched authority and host", location: .here())
            }
        }

        // The path pseudo-header field MUST NOT be empty for "http" or "https" URIs
        if scheme == "https" || scheme == "http" {
            guard !path.isEmpty else {
                throw Self.invalidHeadersError(message: "Path field is empty", location: .here())
            }
        }
    }

    private static func validateConnectRequest(
        _ request: HTTPRequest,
        extendedConnectSupported: Bool
    ) throws(HTTP3Error) {
        precondition(request.method == .connect)

        let scheme = request.scheme
        let path = request.path
        let authority = request.authority

        if request.extendedConnectProtocol != nil {
            // This request contains a :protocol pseudo-header. As such, the rules of RFC 8441 §4 apply.
            guard scheme != nil, path != nil else {
                throw Self.invalidHeadersError(
                    message: "CONNECT request with a :protocol pseudo-header must contain path and scheme",
                    location: .here()
                )
            }

            // A client MUST NOT send an Extended CONNECT request unless we sent SETTINGS_ENABLE_CONNECT_PROTOCOL
            // with a value of 1 (RFC 8441 § 3).
            guard extendedConnectSupported else {
                throw HTTP3Error(
                    code: .extendedConnectNotEnabled,
                    message: "Received an Extended CONNECT request, but Extended CONNECT is not supported",
                    cause: nil,
                    errorCode: .messageError,
                    location: .here()
                )
            }
        } else {
            // A CONNECT request MUST be constructed as follows:

            // 1. The :scheme and :path pseudo-header fields are omitted
            guard scheme == nil && path == nil else {
                throw Self.invalidHeadersError(
                    message: "CONNECT request must not contain path or scheme",
                    location: .here()
                )
            }

            // 2. The :authority pseudo-header field contains the host and port to connect to (equivalent to the
            //   authority-form of the request-target of CONNECT requests; see Section 7.1 of [HTTP]).
            guard let authority else {
                throw Self.invalidHeadersError(message: "CONNECT request must contain authority", location: .here())
            }

            guard Self.isValidConnectAuthority(authority) else {
                throw Self.invalidHeadersError(message: "Invalid :authority pseudo-header value", location: .here())
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

    /// Builds a response from the fields of a response's HEADERS frame.
    @_spi(PackageInternal)
    public static func response(fields: [HTTPField]) throws(HTTP3Error) -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try HTTPResponse(parsed: fields)
        } catch {
            throw Self.unparsableError(message: "Invalid headers", cause: error, location: .here())
        }
        if response.headerFields.contains(.te) {
            throw Self.invalidHeadersError(message: "te field must not be present", location: .here())
        }
        if response.headerFields.contains(.transferEncoding) {
            throw Self.invalidHeadersError(message: "transfer-encoding field must not be present", location: .here())
        }
        return response
    }

    /// Builds the trailers from the fields of a message's trailing HEADERS frame.
    ///
    /// - Returns: The trailers, or `nil` if the frame carried no fields.
    @_spi(PackageInternal)
    public static func trailers(fields: [HTTPField]) throws(HTTP3Error) -> HTTPFields? {
        if fields.isEmpty {
            return nil
        }
        do {
            return try HTTPFields(parsedTrailerFields: fields)
        } catch {
            throw Self.unparsableError(message: "Invalid trailers", cause: error, location: .here())
        }
    }
}

extension HTTPField.Name {
    // `HTTPField.Name.host` is unavailable in HTTPTypes (it steers callers to `:authority`), but
    // RFC 9114 requires us to validate `Host` against `:authority`, so construct the name once.
    static let host = HTTPField.Name(parsed: "host")!
}
