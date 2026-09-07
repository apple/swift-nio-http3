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

enum QUICEncodableInteger {
    /// A QUIC-encoded integer is 62-bit integer (0 to 2^62-1).
    /// See RFC 9000 § 16 for more details.
    static var maxValue: UInt64 { (1 << 62) - 1 }
}
