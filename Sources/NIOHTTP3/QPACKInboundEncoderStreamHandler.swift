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

protocol QPACKInboundEncoderStreamDelegate: ~Copyable {
    func onReceivedInstruction(_ instruction: QPACKEncoderInstruction)

    func onError(_ error: HTTP3Error)
}

/// Read encoder instructions from a channel and give them to a callback.
/// This belongs on the incoming encoder stream.
/// The encoder instructions come from the remote encoder and should be fed into the local decoder.
@available(anyAppleOS 26.0, *)
final class QPACKInboundEncoderStreamHandler<Delegate: QPACKInboundEncoderStreamDelegate>: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let decoder: NIOSingleStepByteToMessageProcessor<QPACKEncoderInstructionDecoder>
    let delegate: Delegate

    init(delegate: consuming Delegate) {
        self.decoder = NIOSingleStepByteToMessageProcessor(QPACKEncoderInstructionDecoder())
        self.delegate = delegate
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        let streamError = HTTP3Error(
            code: .qpackEncoderStreamError,
            message: "Inbound QPACK encoder instruction stream error",
            cause: error,
            errorCode: .qpackEncoderStreamError,
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
                code: .qpackEncoderStreamError,
                message: "Invalid QPACK encoder instruction",
                cause: error,
                errorCode: .qpackEncoderStreamError,
                location: .here()
            )
            self.delegate.onError(streamError)
            context.fireErrorCaught(error)
        }
    }
}
