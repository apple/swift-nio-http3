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

@_spi(PackageInternal)
public enum HTTP3StreamType: Sendable {
    case unidirectional(Unidirectional)
    case request  // Bidirectional streams must be request streams

    /// Unidirectional stream types.
    @_spi(PackageInternal)
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

        /// RFC 9114 § 6.2 specifies the mapping.
        @_spi(PackageInternal)
        public var rawValue: UInt64 {
            switch self {
            case .control: return 0
            case .push: return 1
            case .qpackEncoder: return 2
            case .qpackDecoder: return 3
            case .unknown(let raw): return raw
            }
        }

        @_spi(PackageInternal)
        public var description: String {
            switch self {
            case .control: return "control"
            case .push: return "push"
            case .qpackEncoder: return "qpackEncoder"
            case .qpackDecoder: return "qpackDecoder"
            case .unknown(let raw): return "unknown(\(raw))"
            }
        }

        @_spi(PackageInternal)
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

extension HTTP3StreamType {
    /// Stream types which carry HTTP3 frames (other streams, e.g. qpack streams, do not). This is a subset of ``HTTP3StreamType``.
    @_spi(PackageInternal)
    public enum Framed: Hashable, CustomStringConvertible, Sendable {
        case request
        case push
        case control

        @_spi(PackageInternal)
        public var description: String {
            switch self {
            case .request: return "request"
            case .push: return "push"
            case .control: return "control"
            }
        }
    }

    @_spi(PackageInternal)
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
