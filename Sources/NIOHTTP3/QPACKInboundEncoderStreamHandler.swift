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

package import NIOCore
@_spi(PackageInternal) import QPACK

/// Read encoder instructions from a channel and give them to a callback.
/// This belongs on the incoming encoder stream.
/// The encoder instructions come from the remote encoder and should be fed into the local decoder.
final class QPACKInboundEncoderStreamHandler: ChannelInboundHandler {
    typealias InboundIn = QPACKEncoderInstruction

    /// Called when an incoming instruction is successfully read.
    private var onReceivedInstruction: (QPACKEncoderInstruction) -> Void
    /// Called when an error is caught on this channel.
    private var onError: (any Error) -> Void

    init(
        onReceivedInstruction: @escaping (QPACKEncoderInstruction) -> Void,
        onError: @escaping (any Error) -> Void
    ) {
        self.onReceivedInstruction = onReceivedInstruction
        self.onError = onError
    }

    package func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.onError(error)
        context.fireErrorCaught(error)
    }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let instruction = unwrapInboundIn(data)
        self.onReceivedInstruction(instruction)
        context.fireChannelRead(data)
    }
}
