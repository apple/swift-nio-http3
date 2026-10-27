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

/// A struct representing an HTTP3 push ID.
@available(anyAppleOS 27, *)
public struct HTTP3PushID: Sendable, Hashable {
    /// The underlying raw push ID.
    public var rawValue: UInt64

    /// Initializes a new ``HTTP3PushID``.
    /// - Precondition: The value must be a QUIC-encodable integer, that means it must be between 1 and 2^62-1. Otherwise, this function will trap.
    public init(rawValue: UInt64) {
        precondition(rawValue <= QUICEncodableInteger.maxValue, "Invalid push ID \(rawValue)")
        self.rawValue = rawValue
    }
}

@available(anyAppleOS 27, *)
extension HTTP3PushID: CustomStringConvertible {
    public var description: String {
        "HTTP3PushID(\(self.rawValue))"
    }
}

@available(anyAppleOS 27, *)
extension HTTP3PushID: CustomDebugStringConvertible {
    public var debugDescription: String {
        "HTTP3PushID(\(self.rawValue))"
    }
}
