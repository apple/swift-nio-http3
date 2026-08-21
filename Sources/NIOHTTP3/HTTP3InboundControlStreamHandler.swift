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

import HTTP3
import NIOCore
import NIOQUICHelpers

protocol ControlFrameProcessor {
    func receivedControlFrame(_ frame: HTTP3Frame, streamID: QUICStreamID)
}

@available(anyAppleOS 26, *)
extension HTTP3ConnectionCoordinator: ControlFrameProcessor {}

/// Handler to be used on the incoming control stream only.
final class HTTP3InboundControlStreamHandler<Processor: ControlFrameProcessor>: ChannelInboundHandler,
    RemovableChannelHandler
{
    typealias InboundIn = HTTP3Frame

    private let coordinator: Processor
    private let streamID: QUICStreamID

    init(coordinator: Processor, streamID: QUICStreamID) {
        self.coordinator = coordinator
        self.streamID = streamID
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        self.coordinator.receivedControlFrame(frame, streamID: self.streamID)
        context.fireChannelRead(data)
    }
}
