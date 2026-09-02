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

import DequeModule
@_spi(PackageInternal) import HTTP3
import HTTPTypes
import Logging
import NIOCore
import NIOQUICHelpers

/// This is an internal protocol that shall only be implemented by HTTP3ConnectionCoordinator
/// It exists to enable testing of `HTTP3StreamHandler` in isolation.
protocol HTTP3StreamDelegate {
    /// Tell the connection state when this stream becomes inactive.
    ///
    /// - Parameters:
    ///     - sawEOF: `true` if we read an EOF before closure. That means no incoming frames were dropped.
    ///     - streamID: The closed stream's ID
    ///     - streamType: The closed stream's type
    func onStreamClosed(_ sawEOF: Bool, streamID: QUICStreamID, streamType: HTTP3StreamType.Framed)

    /// Ask the connection coordinator to send connection-level error to the remote peer.
    func onConnectionError(_ error: HTTP3Error)
}

/// This handler should be added to every incoming and outgoing HTTP/3 stream which carries HTTP frames.
/// It handles encoding and decoding of these frames.
/// It will only pass through valid frames, and handles things such as QPACK header decoding.
@available(anyAppleOS 26.0, *)
final class HTTP3StreamHandler<Delegate: HTTP3StreamDelegate, ConnectionDelegate: HTTP3.QPACKConnectionDelegate>:
    ChannelDuplexHandler
{
    typealias InboundIn = ByteBuffer
    typealias InboundOut = HTTP3Frame

    typealias OutboundIn = HTTP3Frame
    typealias OutboundOut = ByteBuffer

    private let streamID: QUICStreamID
    private let streamType: HTTP3StreamType.Framed

    private let delegate: Delegate
    private let qpackCoder: NIOQPACKCoder<ConnectionDelegate, Delegate>

    /// The channel context. This handler can only be in one channel at a time.
    private var context: ChannelHandlerContext?

    /// Bytes for frames that have been written but not yet flushed.
    private var pendingBytes: ByteBuffer?

    /// The promise which will be fulfilled when `pendingBytes` has been written.
    private var pendingPromise: EventLoopPromise<Void>?

    /// The state machine which handles processing incoming bytes into frames, including validating them and decoding QPACK.
    private var stateMachine: HTTP3StreamStateMachine

    /// Accumulates incoming bytes and turns them into ``HTTP3PartialFrameOrUnknown``s.
    private var decoder: NIOSingleStepByteToMessageHandle<HTTP3FrameDecoder>

    /// Whether we fired a channel read which hasn't been followed by a read complete yet.
    private var didFireChannelRead = false

    /// Set whilst we're tearing down. Suppresses asking for QPACK decodes we'd never get a result for.
    private var isInactive = false

    private let logger: Logger

    init(
        stateMachine: consuming HTTP3StreamStateMachine,
        streamID: QUICStreamID,
        streamType: HTTP3StreamType.Framed,
        qpackCoder: NIOQPACKCoder<ConnectionDelegate, Delegate>,
        delegate: Delegate,
        logger: Logger
    ) {
        self.streamID = streamID
        self.streamType = streamType
        self.stateMachine = stateMachine
        self.qpackCoder = qpackCoder
        self.decoder = .init(HTTP3FrameDecoder())
        self.delegate = delegate
        self.logger = logger
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard self.context == nil else {
            fatalError("HTTP3StreamHandler must only be added to one Channel")
        }
        self.context = context
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.logger.trace("HTTP3StreamHandler.channelInactive")

        // Don't leak the pending promise.
        self.pendingBytes = nil
        self.pendingPromise.take()?.fail(ChannelError.ioOnClosedChannel)

        // There's no point asking for QPACK decodes from here on: the channel won't be around by the time we get a
        // result.
        self.isInactive = true

        // We want to flush out anything that's buffered which can be flushed.
        // There's unlikely to be anything...only if we got a channelInactive between a read and a readComplete.
        if !self.stateMachine.isWaitingForHeaderDecode {
            // This is not a clean EOF: an abrupt close may cut a frame in half and that's not an error.
            self.flushFrameDecoder(seenEOF: false, context: context)
        }
        self.fireChannelReadCompleteIfNeeded(context: context)

        // Tell our state machine we closed, and call our callback to tell the connection coordinator too.
        // The coordinator will clean up QPACK state etc.
        switch self.stateMachine.closed() {
        case .streamClosed(let seenEOF):
            self.delegate.onStreamClosed(seenEOF, streamID: self.streamID, streamType: self.streamType)
        case .none:
            break
        }

        // Cleanup reference to avoid leaks.
        self.context = nil
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Don't leak the pending promise.
        self.pendingBytes = nil
        self.pendingPromise.take()?.fail(ChannelError.ioOnClosedChannel)

        // Cleanup reference to avoid leaks.
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = self.unwrapInboundIn(data)
        self.logger.trace("HTTP3StreamHandler.channelRead", metadata: [LoggingKeys.bytes: "\(bytes.readableBytes)"])

        // The state machine either takes ownership of the bytes (queueing them behind an outstanding QPACK decode) or
        // drops them (we already closed or errored). Either way there's nothing for us to do.
        guard self.stateMachine.readyToDecode(bytes) else { return }

        self.decodeInboundBytes(bytes, context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.logger.trace("HTTP3StreamHandler.channelReadComplete")
        // If we're waiting for a QPACK decode, the read complete is queued behind it so that it can't overtake the
        // reads it belongs to.
        guard self.stateMachine.readCompleted() else { return }
        self.fireChannelReadCompleteIfNeeded(context: context)
    }

    /// Feed `buffer` to the frame decoder and push every frame it produces into the state machine.
    ///
    /// - Returns: `true` if all available bytes were processed, `false` if we suspended because we now need a QPACK
    ///   decode result.
    @discardableResult
    private func decodeInboundBytes(_ buffer: ByteBuffer, context: ChannelHandlerContext) -> Bool {
        self.decoder.append(buffer)
        return self.runDecodeLoop(decodeMode: .normal, context: context)
    }

    /// Tell the frame decoder that no more bytes are coming and push out whatever it still holds.
    private func flushFrameDecoder(seenEOF: Bool, context: ChannelHandlerContext) {
        self.runDecodeLoop(decodeMode: .last, seenEOF: seenEOF, context: context)
    }

    /// Pull frames out of the decoder until it runs dry, pushing each one into the state machine.
    ///
    /// - Returns: `true` if the decoder was drained, `false` if we stopped early because a header section needs a
    ///   QPACK decode. Any bytes we didn't consume stay in the handle, so the loop resumes where it left off.
    @discardableResult
    private func runDecodeLoop(
        decodeMode: NIODecodeMode,
        seenEOF: Bool = false,
        context: ChannelHandlerContext
    ) -> Bool {
        while true {
            let next: (decoded: HTTP3PartialFrameOrUnknown?, ended: Bool)
            do {
                next = try self.decoder.decodeNext(decodeMode: decodeMode, seenEOF: seenEOF)
            } catch {
                switch error {
                case .decoder(let error):
                    self.handleDecodeAction(self.stateMachine.frameDecodeError(error), context: context)
                case .payloadTooLarge(let error):
                    context.fireErrorCaught(error)
                }
                return true
            }

            guard let frame = next.decoded else {
                // Either we need more bytes, or `decodeLast` has nothing left to give.
                return true
            }

            let action =
                switch frame {
                case .known(let frame):
                    self.stateMachine.decodedFrame(frame)
                case .unknown:
                    self.stateMachine.decodedUnknownFrame()
                }

            if case .decodeHeader(let partialHeader) = action {
                // Stop here. No further frame may be processed until QPACK has decoded this header section,
                // otherwise frames would overtake it.
                self.requestHeaderDecode(partialHeader)
                return false
            }

            self.handleDecodeAction(action, context: context)

            if next.ended {
                return true
            }
        }
    }

    /// Ask the connection coordinator to decode a header section for us.
    private func requestHeaderDecode(_ partialHeader: HTTP3PartialFrame.Headers) {
        guard !self.isInactive else {
            // No point waiting for a QPACK decode, the channel won't be around by the time we get a result.
            return
        }
        self.logger.trace("HTTP3StreamHandler waiting for QPACK decode")
        self.qpackCoder.decodeHeaders(partialHeader, streamID: self.streamID, decodeReceiver: self)
    }

    private func handleDecodeAction(
        _ action: HTTP3StreamStateMachine.DecodeNextAction,
        context: ChannelHandlerContext
    ) {
        switch action {
        case .returnFrame(let frame):
            self.logger.trace(
                "HTTP3StreamHandler forwarding frame",
                metadata: [LoggingKeys.h3FrameType: "\(frame.type)"]
            )
            context.fireChannelRead(Self.wrapInboundOut(frame))
            self.didFireChannelRead = true
        case .decodeHeader(let partialHeader):
            self.requestHeaderDecode(partialHeader)
        case .emitStreamError(let error):
            context.triggerUserOutboundEvent(
                QUICStopSendingEvent(code: QUICApplicationErrorCode(error.h3ErrorCode ?? .noError)),
                promise: nil
            )
            context.fireErrorCaught(error)
        case .emitConnectionError(let error):
            self.delegate.onConnectionError(error)
        case .alreadyClosed, .previousError, .doNothing:
            // Nothing to do: the frame is dropped.
            break
        }
    }

    private func handleInputClosed(context: ChannelHandlerContext) {
        if !self.stateMachine.isWaitingForHeaderDecode {
            // Push out whatever the frame decoder is still holding before we mark the input as closed. This may
            // suspend again, in which case the closure is queued below.
            self.flushFrameDecoder(seenEOF: true, context: context)
        }

        // Returns nil if the closure was queued behind an outstanding QPACK decode.
        guard let action = self.stateMachine.inputClosed() else { return }

        switch action {
        case .emitEvent:
            context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        case .emitErrorAndEvent(let error):
            context.fireErrorCaught(error)
            context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        case .resetStream(let error):
            context.triggerUserOutboundEvent(
                QUICResetStreamEvent(code: QUICApplicationErrorCode(error.h3ErrorCode ?? .noError)),
                promise: nil
            )
            context.fireErrorCaught(error)
            context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        }
    }

    /// Replay everything which arrived whilst we were blocked on a QPACK decode, in arrival order.
    private func replayPendingReadActions(
        _ actions: consuming UniqueDeque<HTTP3StreamStateMachine.PendingReadAction>,
        context: ChannelHandlerContext
    ) {
        var pending = actions

        // The handle may still be holding bytes it wasn't allowed to decode when we stopped. Those come before
        // anything that was queued, so drain them first.
        guard self.runDecodeLoop(decodeMode: .normal, context: context) else {
            self.stateMachine.enqueue(pending)
            return
        }

        while let action = pending.popFirst() {
            switch action {
            case .decodeFrames(let buffer):
                guard self.decodeInboundBytes(buffer, context: context) else {
                    self.stateMachine.enqueue(pending)
                    return
                }
            case .fireReadComplete:
                self.fireChannelReadCompleteIfNeeded(context: context)
            case .eof:
                self.handleInputClosed(context: context)
                guard !self.stateMachine.isWaitingForHeaderDecode else {
                    // The EOF was requeued by `handleInputClosed`, so everything after it goes behind that.
                    self.stateMachine.enqueue(pending)
                    return
                }
            }
        }
    }

    private func fireChannelReadCompleteIfNeeded(context: ChannelHandlerContext) {
        // If we didn't fire any read then we should also not fire the read complete.
        guard self.didFireChannelRead else { return }
        self.didFireChannelRead = false
        context.fireChannelReadComplete()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
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
            let encoded = self.qpackCoder.encodeHeaders(fields, streamID: self.streamID)
            let action = self.stateMachine.gotHeaderEncodeResult(encoded, into: &self.pendingBytes!)

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

    func flush(context: ChannelHandlerContext) {
        self.emitPendingBytes(context: context)
        context.flush()
    }

    func close(
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

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
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
        case let error as QUICConnectionError:
            self.logger.trace("Caught CONNECTION_CLOSE")
            context.fireErrorCaught(
                HTTP3Error(
                    code: .remoteConnectionError,
                    message: error.reason,
                    cause: error,
                    errorCode: error.isApplication ? HTTP3ErrorCode(rawValue: error.code) : nil,
                    location: .here()
                )
            )
        default:
            context.fireErrorCaught(error)
        }
    }

    /// Call this when `header` has been decoded.
    func onQPACKDecodeResult(fields: [HTTPField]) {
        self.logger.trace("HTTP3StreamHandler.onQPACKDecodeResult")
        guard let context = self.context else {
            // The stream must have been created and registered to get QPACK events and thus already have
            // the context available. Since pending decodes are dropped when the stream closes it must
            // still be open and active.
            fatalError("Tried to deliver QPACK results before handler was added")
        }
        guard let action = self.stateMachine.gotHeaderDecodeResult(fields) else { return }
        self.handleDecodeAction(action.frameAction, context: context)
        self.replayPendingReadActions(action.takeNextActions(), context: context)
    }

    /// Call this if an error is encountered whilst trying to decode `header`.
    func onQPACKDecodeError(_ error: HTTP3Error) {
        guard let context = self.context else {
            // The stream must have been created an registered to get QPACK events and thus already have
            // the context available. Since pending decodes are dropped when the stream closes it must
            // still be open and active.
            fatalError("Tried to deliver QPACK error before handler was set")
        }
        guard let action = self.stateMachine.gotHeaderDecodeError(error) else { return }
        // Anything which was queued behind this decode is dropped: the stream is doomed.
        self.handleDecodeAction(.emitStreamError(action.error), context: context)
        self.fireChannelReadCompleteIfNeeded(context: context)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? ChannelEvent) == ChannelEvent.inputClosed {
            // We don't pass this through immediately, we buffer it behind any buffered reads to prevent overtaking.
            self.logger.trace("HTTP3StreamHandler intercepted inputClosed")
            self.handleInputClosed(context: context)
        } else {
            // Pass it through
            context.fireUserInboundEventTriggered(event)
        }
    }

    /// A GOAWAY frame was sent with an ID lower than or equal to that of this stream.
    /// I.e., we will NOT process this stream, and we should just close it.
    func cancelStreamDueToSendingGoaway() {
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
                errorCode: .requestRejected,
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
    func cancelStreamDueToReceivedGoaway() {
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
    func cancelStreamDueToConnectionClose() {
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

@available(anyAppleOS 26.0, *)
extension HTTP3StreamHandler: QPACKDecodeReceiver {
    func decodeResult(_ result: Result<[HTTPField], HTTP3Error>) {
        switch result {
        case .success(let fields):
            self.onQPACKDecodeResult(fields: fields)
        case .failure(let error):
            self.onQPACKDecodeError(error)
        }
    }
}

@available(*, unavailable)
extension HTTP3StreamHandler: Sendable {}
