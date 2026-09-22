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

/// Read encoder instructions from the peer's QPACK encoder stream. Since we don't allow
/// dynamic QPACK compression, all instructions are rejected and a connection error is
/// emited, if we receive one.
@available(anyAppleOS 26.0, *)
final class QPACKInboundEncoderStreamHandler<Delegate: QPACKInboundStreamDelegate>: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let decoder: NIOSingleStepByteToMessageProcessor<QPACKEncoderInstructionDecoder>
    let delegate: Delegate

    init(delegate: consuming Delegate) {
        self.decoder = NIOSingleStepByteToMessageProcessor(QPACKEncoderInstructionDecoder())
        self.delegate = delegate
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.delegate.onError(
            Self.streamError(
                message: "Inbound QPACK encoder instruction stream error",
                cause: error,
                location: .here()
            )
        )
        context.fireErrorCaught(error)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = Self.unwrapInboundIn(data)
        do {
            try self.decoder.process(buffer: byteBuffer) { instruction in
                // Setting the capacity to zero is the one instruction which doesn't imply a dynamic table.
                guard case .setDynamicTableCapacity(0) = instruction else {
                    throw UnsupportedQPACKInstruction()
                }
            }
        } catch let error as UnsupportedQPACKInstruction {
            let streamError = Self.streamError(
                message: "The peer's QPACK encoder tried to use the dynamic table, which is not supported",
                cause: error,
                location: .here()
            )
            self.delegate.onError(streamError)
            context.fireErrorCaught(streamError)
        } catch {
            self.delegate.onError(
                Self.streamError(message: "Invalid QPACK encoder instruction", cause: error, location: .here())
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
            code: .qpackEncoderStreamError,
            message: message,
            cause: cause,
            errorCode: .qpackEncoderStreamError,
            location: location
        )
    }
}
