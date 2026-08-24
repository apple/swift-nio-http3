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

import NIOCore
@_spi(PackageInternal) import QPACK

/// Read decoder instructions from a channel and give them to a callback.
/// This belongs on the incoming decoder stream.
/// The decoder instructions come from the remote decoder and should be fed into the local encoder.
final class QPACKInboundDecoderStreamHandler: ChannelInboundHandler {
    typealias InboundIn = QPACKDecoderInstruction

    /// Called when an incoming instruction is successfully read.
    private var onReceivedInstruction: (QPACKDecoderInstruction) -> Void
    /// Called when an error is caught on this channel.
    private var onError: (any Error) -> Void

    init(
        onReceivedInstruction: @escaping (QPACKDecoderInstruction) -> Void,
        onError: @escaping (any Error) -> Void
    ) {
        self.onReceivedInstruction = onReceivedInstruction
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.onError(error)
        context.fireErrorCaught(error)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let instruction = unwrapInboundIn(data)
        self.onReceivedInstruction(instruction)
        context.fireChannelRead(data)
    }
}
