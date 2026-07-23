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
package import QPACK

public import struct NIOCore.ByteBuffer

/// Represents a HTTP3 frame which has not been through the qpack decoder yet.
///
/// The types are identical to ``HTTP3Frame`` except that the ``HTTP3PartialFrame/headers(_:)`` and ``HTTP3PartialFrame/pushPromise(_:)`` cases hold encoded field sections instead of fields.
package enum HTTP3PartialFrame: Hashable {
    /// A headers frame for which we don't have the dynamic table references yet.
    /// Pass this to a QPACK decoder to get the full HTTP3Frame.
    package struct Headers: Hashable, Sendable {
        package let fieldSection: FieldSection

        package init(fieldSection: FieldSection) {
            self.fieldSection = fieldSection
        }
    }

    /// A push promise frame for which we don't have the dynamic table references yet.
    /// Pass this to a QPACK decoder to get the full HTTP3Frame.
    package struct PushPromise: Hashable, Sendable {
        package let pushID: HTTP3PushID
        package let fieldSection: FieldSection

        package init(pushID: HTTP3PushID, fieldSection: FieldSection) {
            self.pushID = pushID
            self.fieldSection = fieldSection
        }
    }

    /// A `DATA` frame, containing raw bytes.
    ///
    /// See [RFC 9114 § 7.2.1](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.1)
    case data(HTTP3Frame.Data)

    /// A `HEADERS` frame, containing headers.
    ///
    /// See [RFC 9114 § 7.2.2](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.2)
    case headers(Headers)

    /// A `CANCEL_PUSH` frame, containing the push ID.
    ///
    /// See [RFC 9114 § 7.2.3](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.3)
    case cancelPush(HTTP3Frame.CancelPush)

    /// A `SETTINGS` frame, containing setting parameters.
    ///
    /// See [RFC 9114 § 7.2.4](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.4)
    case settings(HTTP3Frame.Settings)

    /// A `PUSH_PROMISE` frame, containing request header fields.
    ///
    /// See [RFC 9114 § 7.2.5](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.5)
    case pushPromise(PushPromise)

    /// A `GOAWAY` frame.
    ///
    /// See [RFC 9114 § 7.2.6](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.6)
    case goaway(HTTP3Frame.Goaway)

    /// A `MAX_PUSH_ID` frame.
    ///
    /// See [RFC 9114 § 7.2.7](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.7)
    case maxPushID(HTTP3Frame.MaxPushID)
}

/// A representation of a single HTTP/3 frame type.
package enum HTTP3FrameType: Hashable {
    /// Attempts to parse a frame type.
    /// RFC 9114 § 7.2.8: Frame types that were used in HTTP/2 where there is no corresponding HTTP/3 frame have also been reserved (Section 11.2.1).
    /// These frame types MUST NOT be sent, and their receipt MUST be treated as a connection error of type H3\_FRAME\_UNEXPECTED.
    /// - Precondition: The value must be a QUIC-encodable integer, that means it must be between 1 and 2^62-1. Otherwise, this function will trap.
    /// - Throws: If given a forbidden frame type.
    package init(rawValue: UInt64) throws(HTTP3Error) {
        precondition(rawValue <= QUICEncodableInteger.maxValue, "Invalid frame type \(rawValue)")
        @inline(never)
        func forbiddenTypeError(
            rawValue: UInt64,
            location: HTTP3Error.SourceLocation
        ) -> HTTP3Error {
            HTTP3Error(
                code: .forbiddenFrameType,
                message: "\(rawValue) is not allowed",
                cause: nil,
                errorCode: .frameUnexpected,  // RFC 9114 § 7.2.8
                location: location
            )
        }
        switch rawValue {
        case 0x00: self = .data
        case 0x01: self = .headers
        case 0x02: throw forbiddenTypeError(rawValue: rawValue, location: .here())  // This was PRIORITY in http/2
        case 0x03: self = .cancelPush
        case 0x04: self = .settings
        case 0x05: self = .pushPromise
        case 0x06: throw forbiddenTypeError(rawValue: rawValue, location: .here())  // This was PING in http/2
        case 0x07: self = .goaway
        case 0x08: throw forbiddenTypeError(rawValue: rawValue, location: .here())  // This was WINDOW_UPDATE in http/2
        case 0x09: throw forbiddenTypeError(rawValue: rawValue, location: .here())  // This was CONTINUATION in http/2
        case 0x0d: self = .maxPushID
        default: self = .unknown(type: rawValue)
        }
    }

    package var rawValue: UInt64 {
        switch self {
        case .data: return 0x00
        case .headers: return 0x01
        case .cancelPush: return 0x03
        case .settings: return 0x04
        case .pushPromise: return 0x05
        case .goaway: return 0x07
        case .maxPushID: return 0x0d
        case .unknown(let type): return type
        }
    }

    case data
    case headers
    case cancelPush
    case settings
    case pushPromise
    case goaway
    case maxPushID
    case unknown(type: UInt64)
}

/// A representation of a single HTTP/3 frame.
public enum HTTP3Frame: Hashable, Sendable {
    /// The payload of a HTTP/3 DATA frame.
    public struct Data: Hashable, Sendable {
        /// The raw bytes which form the payload of the frame.
        public var payload: ByteBuffer

        /// Initializes a new ``Data``.
        /// - Parameter payload: The raw bytes which form the payload of the frame.
        public init(payload: ByteBuffer) {
            self.payload = payload
        }
    }

    /// The payload of a HTTP/3 HEADERS frame.
    public struct Headers: Hashable, Sendable {
        /// The header fields.
        public var fields: [HTTPField]

        /// Initializes a new ``Headers``.
        /// - Parameter fields: The header fields.
        public init(fields: [HTTPField]) {
            self.fields = fields
        }
    }

    /// The payload of a HTTP/3 CANCEL\_PUSH frame.
    public struct CancelPush: Hashable, Sendable {
        /// ID of the server push being cancelled.
        public var pushID: HTTP3PushID

        /// Initializes a new ``CancelPush``.
        /// - Parameter pushID: ID of the server push being cancelled.
        public init(pushID: HTTP3PushID) {
            self.pushID = pushID
        }
    }

    /// The payload of a HTTP/3 SETTINGS frame.
    public struct Settings: Hashable, Sendable {
        /// The settings contained in the frame.
        public var settings: HTTP3Settings

        /// Initializes a new ``Settings``.
        /// - Parameter settings: The settings contained in the frame.
        public init(settings: HTTP3Settings) {
            self.settings = settings
        }
    }

    /// The payload of a HTTP/3 PUSH\_PROMISE frame.
    public struct PushPromise: Hashable, Sendable {
        /// Identifies the server push operation.
        public var pushID: HTTP3PushID

        /// The fields for the promised response.
        public var httpFields: HTTPFields

        /// Initializes a new ``PushPromise``.
        /// - Parameters:
        ///   - pushID: Identifies the server push operation.
        ///   - httpFields: The fields for the promised response.
        public init(pushID: HTTP3PushID, httpFields: HTTPFields) {
            self.pushID = pushID
            self.httpFields = httpFields
        }
    }

    /// The payload of a HTTP/3 GOAWAY frame.
    public struct Goaway: Hashable, Sendable {
        /// The ID.
        /// For GOAWAY frames sent by a client, this represents a push ID.
        /// For GOAWAY frames sent by a server, this represents a stream ID.
        public var id: HTTP3GoawayID

        /// Initializes a new ``Goaway``.
        /// - Parameter id: The ID of the GOAWAY.
        public init(id: HTTP3GoawayID) {
            self.id = id
        }
    }

    /// The payload of a HTTP/3 MaxPushID frame.
    public struct MaxPushID: Hashable, Sendable {
        /// Identifies the maximum value for a push ID that the server can use.
        public var id: HTTP3PushID

        /// Initializes a new ``MaxPushID``.
        /// - Parameter id: Identifies the maximum value for a push ID that the server can use.
        public init(id: HTTP3PushID) {
            self.id = id
        }
    }

    /// A `DATA` frame, containing raw bytes.
    ///
    /// See [RFC 9114 § 7.2.1](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.1)
    case data(Data)

    /// A `HEADERS` frame, containing headers.
    ///
    /// See [RFC 9114 § 7.2.2](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.2)
    case headers(Headers)

    /// A `CANCEL_PUSH` frame, containing the push ID.
    ///
    /// See [RFC 9114 § 7.2.3](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.3)
    case cancelPush(CancelPush)

    // The SETTINGS case is indirect becuase it's large, forcing the HTTP3Frame type to
    // be boxed when put into an existential if we store it inline. `indirect` moves it
    // out-of-line. The cost for this isn't bad, as we should only send one SETTINGS
    // frame per connection anyway.

    /// A `SETTINGS` frame, containing setting parameters.
    ///
    /// See [RFC 9114 § 7.2.4](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.4)
    indirect case settings(Settings)

    /// A `PUSH_PROMISE` frame, containing request header fields.
    ///
    /// See [RFC 9114 § 7.2.5](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.5)
    case pushPromise(PushPromise)

    /// A `GOAWAY` frame.
    ///
    /// See [RFC 9114 § 7.2.6](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.6)
    case goaway(Goaway)

    /// A `MAX_PUSH_ID` frame.
    ///
    /// See [RFC 9114 § 7.2.7](https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.7)
    case maxPushID(MaxPushID)
}

// MARK: Convenience inits

// The following non-public extensions make it easier to construct frames. We don't want to make these public
// because they are impossible to evolve, hence having structs in the first place.

extension HTTP3PartialFrame {
    package static func data(_ payload: ByteBuffer) -> Self {
        .data(.init(payload: payload))
    }

    package static func settings(_ settings: HTTP3Settings) -> Self {
        .settings(.init(settings: settings))
    }

    package static func cancelPush(_ id: HTTP3PushID) -> Self {
        .cancelPush(.init(pushID: id))
    }

    package static func maxPushID(_ id: HTTP3PushID) -> Self {
        .maxPushID(.init(id: id))
    }

    package static func goaway(_ id: HTTP3GoawayID) -> Self {
        .goaway(.init(id: id))
    }
}

extension HTTP3Frame.Headers {
    /// Whether these headers contain a `:status` pseudo-header field whose value is an informational 1xx status code.
    ///
    /// Returns `false` if the `:status` pseudo-header field is not present or if its value does not represent a 1xx
    /// status code.
    ///
    /// - SeeAlso: https://www.rfc-editor.org/rfc/rfc9110.html#section-15.2.
    package var representsInterimResponse: Bool {
        guard let status = self.fields.first(where: { $0.name == .status })?.value, let code = Int(status) else {
            return false
        }
        return (100..<200).contains(code)
    }
}

extension HTTP3Frame {
    package static func data(_ payload: ByteBuffer) -> Self {
        .data(.init(payload: payload))
    }

    package static func headers(_ fields: [HTTPField]) -> Self {
        .headers(.init(fields: fields))
    }

    package static func settings(_ settings: HTTP3Settings) -> Self {
        .settings(.init(settings: settings))
    }

    package static func cancelPush(_ id: HTTP3PushID) -> Self {
        .cancelPush(CancelPush(pushID: id))
    }

    package static func maxPushID(_ id: HTTP3PushID) -> Self {
        .maxPushID(.init(id: id))
    }

    package static func goaway(_ id: HTTP3GoawayID) -> Self {
        .goaway(.init(id: id))
    }
}
