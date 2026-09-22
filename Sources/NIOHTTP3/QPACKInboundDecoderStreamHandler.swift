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

@_spi(PackageInternal) import HTTP3
import NIOCore
@_spi(PackageInternal) import QPACK

protocol QPACKInboundDecoderStreamDelegate: ~Copyable {
    func onReceivedInstruction(_ instruction: QPACKDecoderInstruction)

    func onError(_ error: HTTP3Error)
}

/// Read decoder instructions from a channel and give them to a callback.
/// This belongs on the incoming decoder stream.
/// The decoder instructions come from the remote decoder and should be fed into the local encoder.
final class QPACKInboundDecoderStreamHandler<Delegate: QPACKInboundDecoderStreamDelegate>: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let decoder: NIOSingleStepByteToMessageProcessor<QPACKDecoderInstructionDecoder>
    let delegate: Delegate

    init(delegate: consuming Delegate) {
        self.decoder = NIOSingleStepByteToMessageProcessor(QPACKDecoderInstructionDecoder())
        self.delegate = delegate
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        let streamError = HTTP3Error(
            code: .qpackDecoderStreamError,
            message: "Inbound QPACK decoder instruction stream error",
            cause: error,
            errorCode: .qpackDecoderStreamError,
            location: .here()
        )
        self.delegate.onError(streamError)
        context.fireErrorCaught(error)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = Self.unwrapInboundIn(data)
        do {
            try self.decoder.process(buffer: byteBuffer) { instruction in
                self.delegate.onReceivedInstruction(instruction)
            }
        } catch {
            let streamError = HTTP3Error(
                code: .qpackDecoderStreamError,
                message: "Invalid QPACK decoder instruction",
                cause: error,
                errorCode: .qpackDecoderStreamError,
                location: .here()
            )
            self.delegate.onError(streamError)
            context.fireErrorCaught(error)
        }
    }
}
