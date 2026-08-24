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

package enum LoggingKeys {
    package static var h3StreamType: String { "h3.stream.type" }
    package static var h3Frame: String { "h3.frame" }
    package static var h3FrameType: String { "h3.frame.type" }
    package static var quicStreamID: String { "quic.stream.id" }
    package static var error: String { "error" }
    package static var bytes: String { "bytes" }
    package static var goawayID: String { "h3.goaway.id" }
    package static var reason: String { "reason" }
}
