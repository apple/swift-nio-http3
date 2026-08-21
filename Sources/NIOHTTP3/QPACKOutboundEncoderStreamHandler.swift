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

final class QPACKOutboundEncoderStreamHandler: ChannelOutboundHandler {
    typealias OutboundIn = QPACKEncoderInstruction
    typealias OutboundOut = QPACKEncoderInstruction

    private var context: ChannelHandlerContext?

    init() {}

    func handlerAdded(context: ChannelHandlerContext) {
        assert(self.context == nil)
        self.context = context
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Break reference cycle
        self.context = nil
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Break reference cycle
        self.context = nil
    }

    func sendInstructions(_ instructions: some Collection<QPACKEncoderInstruction>) {
        guard !instructions.isEmpty else { return }
        guard let context = self.context else {
            // This won't happen because we don't use a dynamic QPACK encoder (and therefore don't send instructions) until
            // the encoder instruction stream is ready and this handler has been added
            assertionFailure("Tried to send QPACK encoder instruction before handler was added")
            return
        }
        for instruction in instructions {
            context.write(self.wrapOutboundOut(instruction), promise: nil)
        }
        context.flush()
    }

    func sendInstruction(_ instruction: QPACKEncoderInstruction) {
        guard let context = self.context else {
            // This won't happen because we don't use a dynamic QPACK encoder (and therefore don't send instructions) until
            // the encoder instruction stream is ready and this handler has been added
            assertionFailure("Tried to send QPACK encoder instruction before handler was added")
            return
        }
        context.writeAndFlush(self.wrapOutboundOut(instruction), promise: nil)
    }
}
