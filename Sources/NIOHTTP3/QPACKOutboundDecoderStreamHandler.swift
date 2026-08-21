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

final class QPACKOutboundDecoderStreamHandler: ChannelOutboundHandler {
    typealias OutboundIn = QPACKDecoderInstruction
    typealias OutboundOut = QPACKDecoderInstruction

    private var context: ChannelHandlerContext?

    init() {}

    func handlerAdded(context: ChannelHandlerContext) {
        assert(self.context == nil)
        self.context = context
    }

    func sendInstruction(_ instruction: QPACKDecoderInstruction) {
        guard let context = self.context else {
            // This won't happen because the QPACK state machine will buffer outgoing instructions until the stream is ready
            assertionFailure("Tried to send instruction before handler was added")
            return
        }
        context.writeAndFlush(self.wrapOutboundOut(instruction), promise: nil)
    }

    func sendInstructions(_ instructions: some Collection<QPACKDecoderInstruction>) {
        guard !instructions.isEmpty else { return }
        guard let context = self.context else {
            // This won't happen because the QPACK state machine will buffer outgoing instructions until the stream is ready
            assertionFailure("Tried to send instruction before handler was added")
            return
        }
        for instruction in instructions {
            context.write(self.wrapOutboundOut(instruction), promise: nil)
        }
        context.flush()
    }
}
