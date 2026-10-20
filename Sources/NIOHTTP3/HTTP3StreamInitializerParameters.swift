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

public import NIOCore
public import NIOQUICHelpers

/// Parameters passed to stream initializer closures provided by users for new incoming or outgoing streams. Gives user access to the channel and stream ID so they can add any custom handlers.
@available(anyAppleOS 27, *)
public struct HTTP3StreamInitializerParameters: Sendable {
    /// The stream channel.
    public var channel: any Channel
    /// The ID of the new stream.
    public var streamID: QUICStreamID

    /// Create a new ``HTTP3StreamInitializerParameters``.
    /// - Note: Users typically do not need to create this object, but it may be useful for testing. An instance of this object will be passed to you in stream initializers.
    /// - Parameters:
    ///   - channel: The stream channel.
    ///   - streamID: The ID of the new stream.
    public init(channel: any Channel, streamID: QUICStreamID) {
        self.channel = channel
        self.streamID = streamID
    }
}

@available(anyAppleOS 27, *)
extension HTTP3StreamInitializerParameters {
    init(_ quicParameters: QUICStreamInitializerParameters) {
        self.init(channel: quicParameters.channel, streamID: quicParameters.streamID)
    }
}
