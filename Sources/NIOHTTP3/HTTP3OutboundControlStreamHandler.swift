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

package import HTTP3
package import NIOCore

/// Handler to be used on the outbound control stream only.
/// Will send the initial settings frame when the channel is ready.
package final class HTTP3OutboundControlStreamHandler: ChannelInboundHandler {
    package typealias OutboundIn = HTTP3Frame
    package typealias OutboundOut = HTTP3Frame
    package typealias InboundIn = Never

    private var context: ChannelHandlerContext?

    private var state: HTTP3OutboundControlStreamStateMachine

    package init(settings: HTTP3Settings) {
        self.state = .init(settings: settings)
    }

    package func handlerAdded(context: ChannelHandlerContext) {
        guard self.context == nil else {
            fatalError("HTTP3OutboundControlStreamHandler must only be added to one Channel")
        }
        self.context = context
        if context.channel.isActive {
            self.handleChannelActive(context: context)
        }
    }

    package func channelInactive(context: ChannelHandlerContext) {
        // Break reference cycle
        self.context = nil
        context.fireChannelInactive()
    }

    package func handlerRemoved(context: ChannelHandlerContext) {
        // Break reference cycle
        self.context = nil
    }

    package func channelActive(context: ChannelHandlerContext) {
        self.handleChannelActive(context: context)
        context.fireChannelActive()
    }

    private func handleChannelActive(context: ChannelHandlerContext) {
        let action = self.state.channelActive()
        switch action {
        case .sendFrames(var frames):
            guard !frames.isEmpty else { return }
            while let frame = frames.popFirst() {
                context.write(self.wrapOutboundOut(frame), promise: nil)
            }
            context.flush()

        case .none:
            break
        }
    }

    /// Send a GOAWAY frame to the peer.
    /// - Parameter id: The ID to be sent. If the remote is a client, this should be a client-initiated, bidirectional stream ID. If the remote is a server, this should be a push ID.
    package func sendGoaway(id: HTTP3GoawayID) {
        switch self.state.sendGoaway(id: id) {
        case .send:
            guard let context = self.context else {
                fatalError("Tried to send go-away on channel which isn't ready")
            }
            context.writeAndFlush(self.wrapOutboundOut(HTTP3Frame.goaway(id)), promise: nil)
        case .none:
            break
        }
    }
}
