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

/// A struct representing the payload of a GOAWAY frame.
///
/// This is either a stream id (if sent by a server) or a push id (if sent by a client).
/// See RFC 9114 § 7.2.6.
public struct HTTP3GoawayID: Sendable, Hashable, RawRepresentable {
    /// The underlying raw ID.
    /// For GOAWAY frames sent by a client, this a push ID.
    /// For GOAWAY frames sent by a server, this is the QUIC ID of a client-initiated bidirectional stream.
    public var rawValue: UInt64

    /// Initializes a new ``HTTP3GoawayID``.
    /// - Precondition: The value must be a QUIC-encodable integer, that means it must be between 1 and 2^62-1. Otherwise, this function will trap.
    public init(rawValue: UInt64) {
        precondition(rawValue <= QUICEncodableInteger.maxValue, "Invalid Goaway ID \(rawValue)")
        self.rawValue = rawValue
    }
}

extension HTTP3GoawayID: CustomStringConvertible {
    public var description: String {
        "HTTP3GoawayID(\(self.rawValue))"
    }
}

extension HTTP3GoawayID: CustomDebugStringConvertible {
    public var debugDescription: String {
        "HTTP3GoawayID(\(self.rawValue))"
    }
}

/// We need to be able to compare goaways internally, but we'll not conform to Comparable publicly.
/// That is because comparing goaways is weird because a goaway id could represent a stream id or a push id and we don't know which it is.
extension HTTP3GoawayID {
    static func < (lhs: HTTP3GoawayID, rhs: HTTP3GoawayID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func <= (lhs: HTTP3GoawayID, rhs: HTTP3GoawayID) -> Bool {
        lhs.rawValue <= rhs.rawValue
    }
}

extension HTTP3GoawayID {
    /// The largest possible GOAWAY ID a server can send (2^62 - 4).
    ///
    /// This is the largest possible client-initiated bidirectional stream ID.
    /// Used for the first GOAWAY frame the server sends during graceful shutdown (RFC 9114 § 5.2).
    public static let maxServerValue = HTTP3GoawayID(rawValue: (1 << 62) - 4)
}

extension QUICStreamID {
    /// A goaway ID sent from a server to a client represents a ``QUICStreamID``.
    init(goawayID: HTTP3GoawayID) {
        self.init(rawValue: goawayID.rawValue)
    }
}

extension HTTP3PushID {
    /// A goaway ID sent from a client to a server represents an ``HTTP3PushID``.
    init(goawayID: HTTP3GoawayID) {
        self.init(rawValue: goawayID.rawValue)
    }
}
