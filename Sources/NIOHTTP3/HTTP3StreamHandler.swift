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
package import HTTPTypes
package import Logging
package import NIOCore
package import NIOQUICHelpers

/// This handler should be added to every incoming and outgoing HTTP/3 stream which carries HTTP frames.
/// It handles encoding and decoding of these frames.
/// It will only pass through valid frames, and handles things such as QPACK header decoding.
package final class HTTP3StreamHandler: ChannelDuplexHandler {
    package typealias InboundIn = ByteBuffer
    package typealias InboundOut = HTTP3Frame

    package typealias OutboundIn = HTTP3Frame
    package typealias OutboundOut = ByteBuffer

    private let streamID: QUICStreamID
    private let streamType: HTTP3StreamType.Framed

    /// Ask the connection coordinator to encode some fields into a partial header.
    /// It will handle sending any necessary instructions to the remote, on the dedicated QPACK stream.
    private let qpackEncoder: ([HTTPField], QUICStreamID) -> HTTP3PartialFrame.Headers
    /// Tell the connection coordinator that we want to decode a header. It will handle queueing and call back into us when it has a result.
    private let qpackDecoder: (HTTP3PartialFrame.Headers, QUICStreamID) -> Void
    /// Tell the connection state when this stream becomes inactive.
    /// - Parameter sawEOF: `true` if we read an EOF before closure. That means no incoming frames were dropped.
    private let onStreamClosed: (_ sawEOF: Bool, QUICStreamID, HTTP3StreamType.Framed) -> Void
    /// Ask the connection coordinator to send connection-level error to the remote peer.
    private let onConnectionError: (HTTP3Error) -> Void

    /// The channel context. This handler can only be in one channel at a time.
    private var context: ChannelHandlerContext?

    /// Bytes for frames that have been written but not yet flushed.
    private var pendingBytes: ByteBuffer?

    /// The promise which will be fulfilled when `pendingBytes` has been written.
    private var pendingPromise: EventLoopPromise<Void>?

    /// The state machine which handles processing incoming bytes into frames, including validating them and decoding QPACK.
    private var stateMachine: HTTP3StreamStateMachine

    private let logger: Logger

    package init(
        stateMachine: consuming HTTP3StreamStateMachine,
        streamID: QUICStreamID,
        streamType: HTTP3StreamType.Framed,
        qpackEncoder: @escaping ([HTTPField], QUICStreamID) -> HTTP3PartialFrame.Headers,
        qpackDecoder: @escaping (HTTP3PartialFrame.Headers, QUICStreamID) -> Void,
        onStreamClosed: @escaping (Bool, QUICStreamID, HTTP3StreamType.Framed) -> Void,
        onConnectionError: @escaping (HTTP3Error) -> Void,
        logger: Logger
    ) {
        self.streamID = streamID
        self.streamType = streamType
        self.stateMachine = stateMachine
        self.qpackEncoder = qpackEncoder
        self.qpackDecoder = qpackDecoder
        self.onStreamClosed = onStreamClosed
        self.onConnectionError = onConnectionError
        self.logger = logger
    }

    package func handlerAdded(context: ChannelHandlerContext) {
        guard self.context == nil else {
            fatalError("HTTP3StreamHandler must only be added to one Channel")
        }
        self.context = context
    }

    package func channelInactive(context: ChannelHandlerContext) {
        self.logger.trace("HTTP3StreamHandler.channelInactive")

        // Don't leak the pending promise.
        self.pendingBytes = nil
        self.pendingPromise.take()?.fail(ChannelError.ioOnClosedChannel)

        // We want to flush out anything that's buffered which can be flushed.
        // There's unlikely to be anything...only if we got a channelInactive between a read and a readComplete.
        // We need to buffer any such actions into an array and save it for after we close the state machine
        var actionBuffer: [HTTP3StreamStateMachine.DecodeNextAction] = []

        loop: while true {
            let action = self.stateMachine.decodeNext()
            switch action {
            case .needMoreBytes, .alreadyClosed, .previousError:
                break loop
            case .returnFrame, .emitConnectionError, .emitStreamError, .decodeHeader, .inputClosed:
                actionBuffer.append(action)
            case .callAgain:
                continue loop
            }
        }

        // Tell our state machine we closed, and call our callback to tell the connection coordinator too.
        // The coordinator will clean up QPACK state etc.
        let closeAction = self.stateMachine.closed()
        switch closeAction {
        case .streamClosed(let seenEOF):
            // unbuffer our read actions
            var didFireChannelRead = false
            loop: for action in actionBuffer {
                switch action {
                case .inputClosed:
                    context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                case .returnFrame(let frame):
                    context.fireChannelRead(wrapInboundOut(frame))
                    didFireChannelRead = true
                case .decodeHeader:
                    // No point waiting for qpack decodes, the channel won't be around by the time we get a result
                    // Then we have to break the whole loop: can't allow further actions to overtake
                    break loop
                case .emitStreamError:
                    // ignore that now
                    break
                case .emitConnectionError(let error):
                    self.onConnectionError(error)
                case .alreadyClosed, .needMoreBytes, .previousError, .callAgain:
                    fatalError("Action shouldn't have been buffered")
                }
            }
            if didFireChannelRead {
                context.fireChannelReadComplete()
            }
            self.onStreamClosed(seenEOF, self.streamID, self.streamType)
        }
        // Cleanup reference to avoid leaks.
        self.context = nil
        context.fireChannelInactive()
    }

    package func handlerRemoved(context: ChannelHandlerContext) {
        // Don't leak the pending promise.
        self.pendingBytes = nil
        self.pendingPromise.take()?.fail(ChannelError.ioOnClosedChannel)

        // Cleanup reference to avoid leaks.
        self.context = nil
    }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = self.unwrapInboundIn(data)
        self.logger.trace("HTTP3StreamHandler.channelRead", metadata: [LoggingKeys.bytes: "\(bytes.readableBytes)"])
        self.stateMachine.buffer(bytes)
    }

    package func channelReadComplete(context: ChannelHandlerContext) {
        self.logger.trace("HTTP3StreamHandler.channelReadComplete")
        // In channelRead, we buffer bytes into the state machine.
        // Now it's time to try and read out as many full frames as possible.
        var didFireChannelRead = false
        decodeLoop: while true {
            let action = self.stateMachine.decodeNext()
            switch action {
            case .inputClosed:
                context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            case .needMoreBytes, .alreadyClosed, .previousError:
                break decodeLoop
            case .callAgain:
                continue decodeLoop
            case .returnFrame(let frame):
                self.logger.trace(
                    "HTTP3StreamHandler forwarding frame",
                    metadata: [LoggingKeys.h3FrameType: "\(frame.type)"]
                )
                context.fireChannelRead(wrapInboundOut(frame))
                didFireChannelRead = true
            case .decodeHeader(let partialHeader):
                self.logger.trace("HTTP3StreamHandler waiting for QPACK decode")
                self.qpackDecoder(partialHeader, self.streamID)
            case .emitStreamError(let error):
                context.triggerUserOutboundEvent(
                    QUICStopSendingEvent(code: QUICApplicationErrorCode(error.h3ErrorCode ?? .H3_NO_ERROR)),
                    promise: nil
                )
                context.fireErrorCaught(error)
            case .emitConnectionError(let error):
                self.onConnectionError(error)
            }
        }
        // If we didn't read anything in this loop then we should also not fire the read complete
        if didFireChannelRead {
            context.fireChannelReadComplete()
        }
    }

    package func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        self.logger.trace("HTTP3StreamHandler.write", metadata: [LoggingKeys.h3FrameType: "\(frame.type)"])

        if self.pendingBytes == nil {
            self.pendingBytes = context.channel.allocator.buffer(capacity: 256)
        }

        let action = self.stateMachine.writeFrame(frame: frame, into: &self.pendingBytes!)

        switch action {
        case .previousError:
            // Just drop the byte
            promise?.fail(
                HTTP3Error(
                    code: .previousError,
                    message: "A previous error is preventing further writes",
                    cause: nil,
                    errorCode: nil,
                    location: .here()
                )
            )
        case .wroteBytes:
            self.pendingPromise.setOrCascade(to: promise)
        case .wouldBeStreamError(let error):
            context.fireErrorCaught(error)
            promise?.fail(error)
        case .alreadyClosed:
            context.fireErrorCaught(ChannelError.ioOnClosedChannel)
            promise?.fail(ChannelError.ioOnClosedChannel)
        case .wouldBeConnectionError(let error):
            context.fireErrorCaught(error)
            promise?.fail(error)
        case .encodeHeaders(let fields):
            let encoded = self.qpackEncoder(fields, self.streamID)
            let action = self.stateMachine.gotHeaderEncodeResult(encoded, from: fields, into: &self.pendingBytes!)

            switch action {
            case .previousError(let previousError):
                promise?.fail(
                    HTTP3Error(
                        code: .previousError,
                        message: "A previous error is preventing further writes",
                        cause: previousError,
                        errorCode: nil,
                        location: .here()
                    )
                )
            case .wroteBytes:
                self.pendingPromise.setOrCascade(to: promise)
            case .alreadyClosed:
                promise?.fail(ChannelError.ioOnClosedChannel)
            }
        }
    }

    package func flush(context: ChannelHandlerContext) {
        self.emitPendingBytes(context: context)
        context.flush()
    }

    package func close(
        context: ChannelHandlerContext,
        mode: CloseMode,
        promise: EventLoopPromise<Void>?
    ) {
        switch mode {
        case .output, .all:
            self.emitPendingBytes(context: context)
        case .input:
            ()
        }
        context.close(mode: mode, promise: promise)
    }

    /// Write any pending bytes.
    private func emitPendingBytes(context: ChannelHandlerContext) {
        if let bytes = self.pendingBytes.take() {
            let promise = self.pendingPromise.take()
            context.write(HTTP3StreamHandler.wrapOutboundOut(bytes), promise: promise)
        }
    }

    package func errorCaught(context: ChannelHandlerContext, error: any Error) {
        switch error {
        case let error as QUICStreamResetError:
            self.logger.trace("Caught RESET_STREAM")
            let action = self.stateMachine.streamErrorCaught(errorCode: error.code)
            switch action {
            case .emitStreamError(let newError):
                context.fireErrorCaught(newError)
            case .none:
                break
            }
        case let error as QUICStopSendingError:
            self.logger.trace("Caught STOP_SENDING")
            let action = self.stateMachine.streamErrorCaught(errorCode: error.code)
            switch action {
            case .emitStreamError(let newError):
                context.fireErrorCaught(newError)
            case .none:
                break
            }
        default:
            context.fireErrorCaught(error)
        }
    }

    /// Call this when `header` has been decoded.
    package func onQPACKDecodeResult(fields: [HTTPField], forHeaders headers: HTTP3PartialFrame.Headers) {
        self.logger.trace("HTTP3StreamHandler.onQPACKDecodeResult")
        guard let context = self.context else {
            // The stream must have been created an registered to get QPACK events and thus already have
            // the context available. Since pending decodes are dropped when the stream closes it must
            // still be open and active.
            fatalError("Tried to deliver QPACK results before handler was added")
        }
        self.stateMachine.gotHeaderDecodeResult(fields, from: headers)
        // Call self.channelReadComplete which will decode and fire reads as much as possible before firing a read complete
        self.channelReadComplete(context: context)
    }

    /// Call this if an error is encountered whilst trying to decode `header`.
    package func onQPACKDecodeError(_ error: HTTP3Error, forHeaders headers: HTTP3PartialFrame.Headers) {
        guard let context = self.context else {
            // The stream must have been created an registered to get QPACK events and thus already have
            // the context available. Since pending decodes are dropped when the stream closes it must
            // still be open and active.
            fatalError("Tried to deliver QPACK error before handler was set")
        }
        self.stateMachine.gotHeaderDecodeError(error, from: headers)
        // Call self.channelReadComplete which will decode and fire reads as much as possible before firing a read complete
        self.channelReadComplete(context: context)
    }

    package func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? ChannelEvent) == ChannelEvent.inputClosed {
            // We don't pass this through immediately, we buffer it behind any buffered reads to prevent overtaking.
            self.logger.trace("HTTP3StreamHandler intercepted inputClosed")
            self.stateMachine.inputClosed()
        } else {
            // Pass it through
            context.fireUserInboundEventTriggered(event)
        }
    }

    /// A GOAWAY frame was sent with an ID lower than or equal to that of this stream.
    /// I.e., we will NOT process this stream, and we should just close it.
    package func cancelStreamDueToSendingGoaway() {
        guard let context = self.context else {
            assertionFailure("Tried to send cancel stream before handler was added")
            return
        }

        @inline(never)
        func streamCancelledDueToSendingGoawayError(location: HTTP3Error.SourceLocation) -> HTTP3Error {
            HTTP3Error(
                code: .rejected,
                message: "Stream cancelled due to GOAWAY",
                cause: nil,
                errorCode: .H3_REQUEST_REJECTED,
                location: location
            )
        }
        self.logger.trace("Sending goaway, closing stream")
        let error = streamCancelledDueToSendingGoawayError(location: .here())
        self.triggerUserOutboundEvent(
            context: context,
            event: QUICResetStreamEvent(code: QUICApplicationErrorCode(error.h3ErrorCode!)),
            promise: nil
        )
        context.fireErrorCaught(error)
    }

    /// A GOAWAY frame was received with an ID lower than or equal to that of this stream.
    /// I.e., the remote will NOT process this stream, and we should just close it.
    package func cancelStreamDueToReceivedGoaway() {
        guard let context = self.context else {
            assertionFailure("Tried to propagate stream cancelation before handler was added")
            return
        }
        @inline(never)
        func streamCancelledDueToReceivedGoawayError(location: HTTP3Error.SourceLocation) -> HTTP3Error {
            HTTP3Error(
                code: .rejected,
                message: "Stream cancelled due to GOAWAY",
                cause: nil,
                errorCode: nil,  // This error isn't being sent to remote, so code is not relevant.
                location: location
            )
        }
        self.logger.trace("Received goaway, closing stream")
        let error = streamCancelledDueToReceivedGoawayError(location: .here())
        context.fireErrorCaught(error)
        // Defer close to ensure error propagates first
        let loopBoundContext = NIOLoopBound.init(context, eventLoop: context.eventLoop)
        context.eventLoop.execute {
            loopBoundContext.value.close(mode: .all, promise: nil)
        }
    }

    /// The remote closed the connection (CONNECTION_CLOSE). All active streams must be cancelled.
    package func cancelStreamDueToConnectionClose() {
        guard let context = self.context else {
            assertionFailure("Tried to cancel stream before handler was added")
            return
        }
        @inline(never)
        func streamCancelledDueToConnectionCloseError(location: HTTP3Error.SourceLocation) -> HTTP3Error {
            HTTP3Error(
                code: .remoteConnectionError,
                message: "Stream cancelled due to connection close",
                cause: nil,
                errorCode: nil,
                location: location
            )
        }
        self.logger.trace("Connection closed, closing stream")
        let error = streamCancelledDueToConnectionCloseError(location: .here())
        context.fireErrorCaught(error)
        // Defer close to ensure error propagates first
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.eventLoop.execute {
            loopBoundContext.value.close(mode: .all, promise: nil)
        }
    }
}

@available(*, unavailable)
extension HTTP3StreamHandler: Sendable {}
