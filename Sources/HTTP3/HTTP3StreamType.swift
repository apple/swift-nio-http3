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

import NIOQUICHelpers

/// The type of an HTTP/3 stream (RFC 9114 § 6).
@available(anyAppleOS 27, *)
public enum HTTP3StreamType: Sendable {
    /// A unidirectional stream. Its type is the first variable-length integer on the stream.
    case unidirectional(Unidirectional)
    /// A request stream. All bidirectional streams are request streams.
    case request

    /// Unidirectional stream types (RFC 9114 § 6.2).
    ///
    /// Write one at the start of a unidirectional stream with ``OutputRawSpan/appendHTTP3StreamType(_:)``.
    public enum Unidirectional: Hashable, RawRepresentable, CustomStringConvertible, Sendable {
        /// Type 0x00. Carries HTTP3 frames such as settings, goaway, etc.
        case control
        /// Type 0x01. Carries HTTP3 frames to fulfill a previously promised push.
        case push
        /// Type 0x02. Carries an unframed sequence of encoder instructions, encoder to decoder.
        case qpackEncoder
        /// Type 0x03. Carries an unframed sequence of decoder instructions, decoder to encoder.
        case qpackDecoder
        /// Type not known to this implementation.
        case unknown(raw: UInt64)

        /// The stream type value sent on the wire. RFC 9114 § 6.2 specifies the mapping.
        public var rawValue: UInt64 {
            switch self {
            case .control: return 0
            case .push: return 1
            case .qpackEncoder: return 2
            case .qpackDecoder: return 3
            case .unknown(let raw): return raw
            }
        }

        public var description: String {
            switch self {
            case .control: return "control"
            case .push: return "push"
            case .qpackEncoder: return "qpackEncoder"
            case .qpackDecoder: return "qpackDecoder"
            case .unknown(let raw): return "unknown(\(raw))"
            }
        }

        /// Creates a stream type from its wire value. Unknown values map to ``unknown(raw:)``.
        ///
        /// - Precondition: `rawValue` must fit in a QUIC variable-length integer (at most 2^62 - 1).
        public init(rawValue: UInt64) {
            precondition(rawValue <= QUICEncodableInteger.maxValue, "Invalid stream type \(rawValue)")
            switch rawValue {
            case 0:
                self = .control
            case 1:
                self = .push
            case 2:
                self = .qpackEncoder
            case 3:
                self = .qpackDecoder
            default:
                self = .unknown(raw: rawValue)
            }
        }
    }
}

@available(anyAppleOS 27, *)
extension HTTP3StreamType {
    /// Stream types which carry HTTP3 frames (other streams, e.g. qpack streams, do not). This is a subset of ``HTTP3StreamType``.
    public enum Framed: Hashable, CustomStringConvertible, Sendable {
        /// A request stream.
        case request
        /// A push stream.
        case push
        /// The control stream.
        case control

        public var description: String {
            switch self {
            case .request: return "request"
            case .push: return "push"
            case .control: return "control"
            }
        }
    }

    /// Creates the stream type of a framed stream.
    public init(_ framed: Framed) {
        switch framed {
        case .request:
            self = .request
        case .push:
            self = .unidirectional(.push)
        case .control:
            self = .unidirectional(.control)
        }
    }
}
