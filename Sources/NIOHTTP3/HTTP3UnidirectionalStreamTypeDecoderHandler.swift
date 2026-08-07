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
package import Logging
package import NIOCore
import NIOQUICHelpers

/// Read the incoming stream header (the first byte). Inform the callback when the stream type is known.
/// Buffers all data after the stream type until told to release the queue.
/// This is only used for unidirectional streams. Bidirectional streams do not send a stream header. Their type is always request.
/// See RFC 9114 § 6.2 for more information.
package final class HTTP3UnidirectionalStreamTypeDecoderHandler: ChannelInboundHandler, RemovableChannelHandler {
    package typealias InboundIn = ByteBuffer
    package typealias InboundOut = ByteBuffer

    package enum DecodeResult {
        /// Return this from the callback when the stream type is valid, and the pipeline is ready to receive data.
        case ready
    }

    private let logger: Logger
    /// Will be called exactly once, when the stream type is known. Should return a future that is fulfilled when the pipeline is ready.
    /// Fail this promise to reject the stream. If failed with a `HTTP3Error` then the error code from that will be sent to the remote.
    /// Otherwise, H3\_INTERNAL\_ERROR will be used.
    /// - Precondition: The EventLoopFuture returned here MUST be on the same EventLoop as the EventLoop this handler is on.
    private let callback: (HTTP3StreamType.Unidirectional) -> EventLoopFuture<DecodeResult>

    private var state = HTTP3UnidirectionalStreamTypeDecoderStateMachine()
    private var context: ChannelHandlerContext?

    package init(logger: Logger, callback: @escaping (HTTP3StreamType.Unidirectional) -> EventLoopFuture<DecodeResult>)
    {
        self.logger = logger
        self.callback = callback
    }

    package func handlerAdded(context: ChannelHandlerContext) {
        guard self.context == nil else {
            fatalError("HTTP3UnidirectionalStreamTypeDecoderHandler must only be added to one Channel")
        }
        self.context = context
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

    /// Will release all queued data into the pipeline and remove self from pipeline.
    /// Call this once the stream type is known, this handler is not needed after that point.
    /// You should not release the queue before the stream type is known.
    private func releaseQueue() {
        guard let context = self.context else {
            fatalError("Tried to release queue but missing context")
        }
        // We must call unbufferElement in a loop until `done` is returned
        var didFireChannelRead = false
        loop: while true {
            let action = self.state.unbufferElement()
            switch action {
            case .release(let data):
                // Fire queued data down the pipeline
                context.fireChannelRead(wrapInboundOut(data))
                didFireChannelRead = true
            case .done:
                if didFireChannelRead {
                    context.fireChannelReadComplete()
                }
                // Remove self, this handler has no more work to do
                context.pipeline.syncOperations.removeHandler(self, promise: nil)
                break loop
            }
        }
    }

    /// Send the error code to the remote and close the stream.
    /// - Parameter errorCode: The error code to send to the remote peer.
    private func sendStreamReset(errorCode: HTTP3ErrorCode) {
        guard let context = self.context else {
            fatalError("Tried to send stream reset but missing context")
        }
        self.state.abortReading()
        context.triggerUserOutboundEvent(
            QUICStopSendingEvent(code: QUICApplicationErrorCode(errorCode)),
            promise: nil
        )
    }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        switch self.state.buffer(data: data) {
        case .none: break
        case .gotStreamType(let type):
            var logger = self.logger
            logger[metadataKey: LoggingKeys.h3StreamType] = "\(type.rawValue)"
            self.callback(type).assumeIsolated().whenComplete { [logger] in
                switch $0 {
                case .success(.ready):
                    logger.trace("Initialized inbound stream")
                    self.releaseQueue()
                case .failure(let error):
                    logger.error("Failed to initialize inbound stream", metadata: [LoggingKeys.error: "\(error)"])
                    // The callback threw an error, we should close the stream
                    if let h3Error = error as? HTTP3Error {
                        context.fireErrorCaught(h3Error)
                        self.sendStreamReset(errorCode: h3Error.h3ErrorCode ?? .internalError)
                    } else {
                        @inline(never)
                        func streamCreationError(
                            cause: any Error,
                            location: HTTP3Error.SourceLocation
                        ) -> HTTP3Error {
                            HTTP3Error(
                                code: .streamCreationError,
                                message: "Failed to initialize inbound stream",
                                cause: cause,
                                errorCode: .internalError,
                                location: location
                            )
                        }
                        let h3Error = streamCreationError(cause: error, location: .here())
                        context.fireErrorCaught(h3Error)
                        self.sendStreamReset(errorCode: .internalError)
                    }
                }
            }
        }
    }
}

@available(*, unavailable)
extension HTTP3UnidirectionalStreamTypeDecoderHandler: Sendable {}
