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

/// Read decoder instructions from the peer's QPACK decoder stream. Since we don't allow
/// dynamic QPACK compression, all instructions are rejected and a connection error is
/// emited, if we receive one.
final class QPACKInboundDecoderStreamHandler<Delegate: QPACKInboundStreamDelegate>: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let decoder: NIOSingleStepByteToMessageProcessor<QPACKDecoderInstructionDecoder>
    let delegate: Delegate

    init(delegate: consuming Delegate) {
        self.decoder = NIOSingleStepByteToMessageProcessor(QPACKDecoderInstructionDecoder())
        self.delegate = delegate
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.delegate.onError(
            Self.streamError(
                message: "Inbound QPACK decoder instruction stream error",
                cause: error,
                location: .here()
            )
        )
        context.fireErrorCaught(error)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = Self.unwrapInboundIn(data)
        do {
            try self.decoder.process(buffer: byteBuffer) { _ in
                throw UnsupportedQPACKInstruction()
            }
        } catch let error as UnsupportedQPACKInstruction {
            let streamError = Self.streamError(
                message: "Received a QPACK decoder instruction, but the dynamic table is not in use",
                cause: error,
                location: .here()
            )
            self.delegate.onError(streamError)
            context.fireErrorCaught(streamError)
        } catch {
            self.delegate.onError(
                Self.streamError(message: "Invalid QPACK decoder instruction", cause: error, location: .here())
            )
            context.fireErrorCaught(error)
        }
    }

    @inline(never)
    private static func streamError(
        message: String,
        cause: any Error,
        location: HTTP3Error.SourceLocation
    ) -> HTTP3Error {
        HTTP3Error(
            code: .qpackDecoderStreamError,
            message: message,
            cause: cause,
            errorCode: .qpackDecoderStreamError,
            location: location
        )
    }
}
