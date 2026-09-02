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

public import DequeModule
public import HTTPTypes

public import struct NIOCore.ByteBuffer
public import struct NIOQUICHelpers.QUICApplicationErrorCode

@_spi(PackageInternal)
public struct HTTP3StreamStateMachine: ~Copyable {
    /// This state machine handles the reading side of the stream only.
    ///
    /// Frames are pushed into it, one at a time, via `decodedNext(_:)`. The bytes those frames were decoded from are
    /// owned by the caller (in practice a `NIOSingleStepByteToMessageProcessor`), not by this state machine.
    ///
    /// Sometimes, `decodedNext(_:)` will return the `decodeHeader` action, in which case you need to decode those
    /// headers and call `gotHeaderDecodeResult`. Whilst that decode is outstanding, no further frames may be pushed
    /// in: everything that arrives in the meantime (raw bytes, read completions, EOF) is queued as a
    /// ``PendingReadAction`` and handed back once the decode result arrives, so that ordering is maintained.
    struct ReadState: ~Copyable {
        private enum State: ~Copyable {
            /// Nothing special is happening on the read side.
            case idle

            /// We have read a partial header. We can't take further frames out of the decoder until this header is decoded.
            case waitingForDecode(WaitingForDecode)

            /// Input is closed, we can receive no more.
            case inputClosed

            struct WaitingForDecode: ~Copyable {
                /// Everything that arrived whilst we were waiting for the QPACK decode result, in arrival order.
                var waiting: UniqueDeque<PendingReadAction>

                init() {
                    self.waiting = .init()
                }
            }
        }

        private let state: State

        init() {
            self.init(state: .idle)
        }

        private init(state: consuming State) {
            self.state = state
        }

        /// Whether we are currently blocked on a QPACK decode result.
        var isWaitingForHeaderDecode: Bool {
            switch self.state {
            case .waitingForDecode: return true
            case .idle: return false
            case .inputClosed: return false
            }
        }

        /// Whether we have seen the EOF and surfaced it.
        var hasSeenEOF: Bool {
            switch self.state {
            case .inputClosed: return true
            case .idle: return false
            case .waitingForDecode: return false
            }
        }

        /// Ask whether `buffer` may be handed to the frame decoder right now.
        ///
        /// - Returns: `true` if the caller should decode the buffer now. `false` if it must not: either the bytes were
        ///   queued behind an outstanding QPACK decode, or they should be dropped.
        mutating func readyToDecode(_ buffer: ByteBuffer) -> Bool {
            switch consume self.state {
            case .idle:
                self = .init(state: .idle)
                return true
            case .waitingForDecode(var waitingForDecode):
                waitingForDecode.waiting.append(.decodeFrames(buffer))
                self = .init(state: .waitingForDecode(waitingForDecode))
                return false
            case .inputClosed:
                // The peer shouldn't send anything after the FIN, but we can't stop it from trying. Drop the bytes.
                self = .init(state: .inputClosed)
                return false
            }
        }

        /// Ask whether a read completion may be forwarded right now.
        ///
        /// - Returns: `true` if the caller should forward it now, `false` if it was queued behind an outstanding
        ///   QPACK decode.
        mutating func readCompleted() -> Bool {
            switch consume self.state {
            case .idle:
                self = .init(state: .idle)
                return true
            case .waitingForDecode(var waitingForDecode):
                waitingForDecode.waiting.append(.fireReadComplete)
                self = .init(state: .waitingForDecode(waitingForDecode))
                return false
            case .inputClosed:
                self = .init(state: .inputClosed)
                return true
            }
        }

        /// Queue actions which couldn't be replayed because we became blocked on another QPACK decode.
        ///
        /// The queue is always empty when we newly block, and nothing can arrive during the (synchronous) replay, so
        /// appending preserves ordering.
        mutating func enqueue(_ actions: consuming UniqueDeque<PendingReadAction>) {
            switch consume self.state {
            case .waitingForDecode(var waitingForDecode):
                var actions = actions
                while let action = actions.popFirst() {
                    waitingForDecode.waiting.append(action)
                }
                self = .init(state: .waitingForDecode(waitingForDecode))
            case .idle:
                assertionFailure("Actions can only be requeued whilst waiting for a decode")
                self = .init(state: .idle)
            case .inputClosed:
                assertionFailure("Actions can only be requeued whilst waiting for a decode")
                self = .init(state: .inputClosed)
            }
        }

        enum DecodeNextAction {
            /// A full frame is ready.
            case returnFrame(HTTP3Frame)
            /// An unknown frame was encountered.
            case returnUnknownFrame
            /// An error happened at the connection level.
            case emitConnectionError(HTTP3Error)
            /// An error happened at the stream level.
            case emitStreamError(HTTP3Error)
            /// We need this header to be decoded.
            case decodeHeader(HTTP3PartialFrame.Headers)
            /// There is no action because the input was already closed.
            case alreadyClosed
            /// There is nothing to do for this frame.
            case doNothing
        }

        /// Push the next decoded frame in. This may ask you to run QPACK on some partial headers.
        mutating func decodedNext(_ frame: HTTP3PartialFrame) -> DecodeNextAction {
            switch consume self.state {
            case .idle:
                switch frame {
                case .headers(let partialHeader):
                    self = .init(state: .waitingForDecode(.init()))
                    return .decodeHeader(partialHeader)
                case .pushPromise:
                    self = .init(state: .idle)
                    // RFC 9114 § 7.2.5: A server MUST NOT use a push ID that is larger than the client has provided in a MAX_PUSH_ID frame (Section 7.2.7).
                    // A client MUST treat receipt of a PUSH_PROMISE frame that contains a larger push ID than the client has advertised as a connection error of H3_ID_ERROR.
                    // RFC 9114 § 7.2.7: ... a server cannot push until it receives a MAX_PUSH_ID frame.
                    // We don't support push at all in this implementation, and provide no way to send a max push id. Therefore, _any_ push promise is above the max ID and therefore not allowed
                    return .emitConnectionError(
                        .init(
                            code: .unexpectedFrame,
                            message: "Unexpected push promise",
                            cause: nil,
                            errorCode: .idError,
                            location: .here()
                        )
                    )
                case .cancelPush, .data, .goaway, .maxPushID, .settings:
                    self = .init(state: .idle)
                    return .returnFrame(frame.asFullFrameNotHeadersOrPush())
                }
            case .waitingForDecode(let waitingState):
                // The caller must consult `readyToDecode(_:)` before feeding the frame decoder, so this can't happen.
                assertionFailure("Frames must not be decoded whilst waiting for a QPACK decode result")
                self = .init(state: .waitingForDecode(waitingState))
                return .doNothing
            case .inputClosed:
                self = .init(state: .inputClosed)
                return .alreadyClosed
            }
        }

        /// Inform the state machine of a qpack decode result that has been previously asked for.
        /// It is an error to call this function with a result for a partial header which wasn't asked for.
        /// - Returns: The actions which were queued behind the decode, in arrival order.
        mutating func gotHeaderDecodeResult() -> UniqueDeque<PendingReadAction> {
            switch consume self.state {
            case .waitingForDecode(let waitingState):
                self = .init(state: .idle)
                return waitingState.waiting

            case .idle:
                assertionFailure("Unexpected header decode")
                self = .init(state: .idle)
                return .init()
            case .inputClosed:
                assertionFailure("Unexpected header decode")
                self = .init(state: .inputClosed)
                return .init()
            }
        }

        /// Inform the state machine of a qpack decode error for a header that the machine previously asked to decode.
        /// It is an error to call this function with a result for a partial header which wasn't asked for.
        mutating func gotHeaderDecodeError() -> Bool {
            switch consume self.state {
            case .idle:
                assertionFailure("Unexpected header decode")
                self = .init(state: .idle)
                return false
            case .inputClosed:
                assertionFailure("Unexpected header decode")
                self = .init(state: .inputClosed)
                return false
            case .waitingForDecode:
                // this implicitly drops any buffers and read completions that we may have received in the meantime
                self = .init(state: .idle)
                return true
            }
        }

        /// Call this when there is nothing left to read.
        /// - Returns: `true` if the caller should act on the closure now, `false` if it was queued behind an
        ///   outstanding QPACK decode.
        mutating func inputClosed() -> Bool {
            switch consume self.state {
            case .waitingForDecode(var buffered):
                buffered.waiting.append(.eof)
                self = .init(state: .waitingForDecode(buffered))
                return false
            case .idle:
                self = .init(state: .inputClosed)
                return true
            case .inputClosed:
                assertionFailure("Invalid state: We are already closed.")
                self = .init(state: .inputClosed)
                return false
            }
        }

        @_spi(PackageInternal)
        public enum FinishType {
            /// We had seen EOF before the close.
            case sawEOF
            /// We hadn't seen EOF before the close.
            case noEOF
        }

        /// Call this when the stream is completely closed. This will tell you whether or not we saw an EOF, i.e. any frames were potentially dropped.
        /// This function is consuming, the state machine can't be used after closing.
        consuming func closed() -> FinishType {
            switch consume self.state {
            case .idle:
                return .noEOF
            case .waitingForDecode:
                // We may have a queued EOF, but we never got to unbuffer it, so this is not a clean close.
                return .noEOF
            case .inputClosed:
                // Input was already closed, so it's clean
                return .sawEOF
            }
        }
    }

    /// This state machine handles the writing side of the stream only.
    /// You call `write` to give it a full frame (not qpack encoded).
    /// The resulting action will either give bytes to write out, or ask to run something through qpack.
    /// You must call gotHeaderEncodeResult with the result of that BEFORE trying to write any different frame.
    struct WriteState: ~Copyable {
        private enum State: ~Copyable {
            /// Nothing special is happening on the write side.
            case idle(Idle)

            /// We have tried to write a header. We need the result of encoding these fields before we can proceed.
            case waitingForEncode(WaitingForEncode)

            struct Idle: ~Copyable {
                var preferHuffmanEncoding: Bool
            }

            struct WaitingForEncode {
                let fields: [HTTPField]
                var preferHuffmanEncoding: Bool

                init(idleState: consuming Idle, fields: [HTTPField]) {
                    self.fields = fields
                    self.preferHuffmanEncoding = idleState.preferHuffmanEncoding
                }
            }
        }

        private let state: State

        init(preferHuffmanEncoding: Bool) {
            self.init(state: .idle(.init(preferHuffmanEncoding: preferHuffmanEncoding)))
        }

        private init(state: consuming State) {
            self.state = state
        }

        enum WriteAction {
            /// The frame's bytes were appended to the provided buffer.
            case wroteBytes
            /// We need this header to be encoder.
            case encodeHeaders([HTTPField])
        }

        /// Write a frame out by appending its encoded bytes to `buffer`.
        mutating func write(frame: HTTP3Frame, into buffer: inout ByteBuffer) -> WriteAction {
            switch consume self.state {
            case .idle(let idleState):
                let maybePartial = MaybePartialFrame(frame)
                switch maybePartial {
                case .headers(let headers):
                    self = .init(state: .waitingForEncode(.init(idleState: idleState, fields: headers.fields)))
                    return .encodeHeaders(headers.fields)
                case .pushPromise:
                    // This cannot be reached. The validator currently forbids writing push promises at all
                    // For clients, that is correct
                    // For servers, it's because we haven't implemented push yet. It would be wrong
                    // for a server using this http/3 implementation to try to write a push promise frame because we don't
                    // expose push streams or the max push id yet. Therefore we forbid writing them in the validator.
                    // So it won't get this far.
                    fatalError("Tried to write a push promise, which is not supported")
                case .partial(let partial):
                    buffer.writeHTTP3PartialFrame(partial, preferHuffmanEncoding: idleState.preferHuffmanEncoding)
                    self = .init(state: .idle(idleState))
                    return .wroteBytes
                }
            case .waitingForEncode:
                fatalError("Cannot call write whilst waiting for a QPACK encode result")
            }
        }

        enum HeaderEncodeResultAction {
            /// The header's bytes were appended to the provided buffer.
            case wroteBytes
        }

        mutating func gotHeaderEncodeResult(
            _ result: HTTP3PartialFrame.Headers,
            from: [HTTPField],
            into buffer: inout ByteBuffer
        ) -> HeaderEncodeResultAction {
            switch consume self.state {
            case .idle:
                fatalError("Unexpected encode result")
            case .waitingForEncode(let waitingState):
                guard from == waitingState.fields else {
                    fatalError("Unexpected encode result")
                }
                buffer.writeHTTP3PartialFrame(
                    .headers(result),
                    preferHuffmanEncoding: waitingState.preferHuffmanEncoding
                )
                self = .init(state: .idle(.init(preferHuffmanEncoding: waitingState.preferHuffmanEncoding)))
                return .wroteBytes
            }
        }
    }

    enum State: ~Copyable {
        /// We are currently not doing anything special.
        case idle(Idle)

        /// We previously hit an error, and now can't do anything.
        case previousError(PreviousErrorState)

        /// The stream is closed.
        case finished

        struct Idle: ~Copyable {
            var validator: HTTP3FrameValidator
            var readState: ReadState
            var writeState: WriteState
        }

        /// The state contained in ``State/previousError(_:)``.
        struct PreviousErrorState: ~Copyable {
            /// The error that was reached. This is reported back on any subsequent operation.
            var error: HTTP3Error

            /// Whether the read side had already seen the EOF when the error occurred.
            var seenEOF: Bool
        }
    }

    private let state: State

    @_spi(PackageInternal)
    public init(
        streamType: HTTP3StreamType.Framed,
        incoming: Bool,
        preferHuffmanEncoding: Bool
    ) {
        let frameValidator = HTTP3FrameValidator(streamType: streamType, incoming: incoming)
        let readState = ReadState()
        let writeState = WriteState(preferHuffmanEncoding: preferHuffmanEncoding)
        self.init(state: .idle(.init(validator: frameValidator, readState: readState, writeState: writeState)))
    }

    private init(state: consuming State) {
        self.state = state
    }

    @_spi(PackageInternal)
    public enum WriteFrameAction {
        /// The frame's bytes were appended to the buffer you provided.
        case wroteBytes
        /// You should encode the given headers and call back with the result.
        case encodeHeaders([HTTPField])
        /// The frame can't be written, because doing so would be a stream error.
        case wouldBeStreamError(HTTP3Error)
        /// The frame can't be written, because doing so would be a connection error.
        case wouldBeConnectionError(HTTP3Error)
        /// This frame can't be written because the stream has already closed
        case alreadyClosed
        /// This frame can't be written because we already encountered an error on this stream.
        case previousError
    }

    /// Write out a frame by appending its encoded bytes to `buffer`.
    @_spi(PackageInternal)
    public mutating func writeFrame(frame: HTTP3Frame, into buffer: inout ByteBuffer) -> WriteFrameAction {
        switch self.state {
        case .idle(var idleState):
            let validationResult = idleState.validator.processOutboundFrame(frame)
            switch validationResult {
            case .forwardFrame(let validatedFrame):
                let writeAction = idleState.writeState.write(frame: validatedFrame, into: &buffer)
                switch writeAction {
                case .wroteBytes:
                    self = .init(state: .idle(idleState))
                    return .wroteBytes
                case .encodeHeaders(let fields):
                    self = .init(state: .idle(idleState))
                    return .encodeHeaders(fields)
                }
            case .emitStreamError(let error):
                self = .init(state: .previousError(.init(error: error, seenEOF: idleState.readState.hasSeenEOF)))
                return .wouldBeStreamError(error)
            case .emitConnectionError(let error):
                self = .init(state: .previousError(.init(error: error, seenEOF: idleState.readState.hasSeenEOF)))
                return .wouldBeConnectionError(error)
            case .previousError:
                self = .init(state: .idle(idleState))
                return .previousError
            }
        case .previousError(let error):
            self = .init(state: .previousError(error))
            return .previousError
        case .finished:
            self = .init(state: .finished)
            return .alreadyClosed
        }
    }

    @_spi(PackageInternal)
    public enum HeaderEncodeResultAction {
        /// The header's bytes were appended to the buffer you provided.
        case wroteBytes
        /// This header can't be encoded because the stream is already in an error state.
        case previousError(HTTP3Error)
        /// You should fail the current write because the stream is already closed
        case alreadyClosed
    }

    @_spi(PackageInternal)
    public mutating func gotHeaderEncodeResult(
        _ result: HTTP3PartialFrame.Headers,
        from: [HTTPField],
        into buffer: inout ByteBuffer
    ) -> HeaderEncodeResultAction {
        switch self.state {
        case .idle(var idleState):
            let writeAction = idleState.writeState.gotHeaderEncodeResult(result, from: from, into: &buffer)
            self = .init(state: .idle(idleState))
            switch writeAction {
            case .wroteBytes:
                return .wroteBytes
            }
        case .finished:
            // We shouldn't get a header decode result on a finished stream.
            // This can only really happen if we shut down the stream during a write, whilst doing the qpack encode.
            // But if we do, just drop it, nobody is waiting for it now.
            self = .init(state: .finished)
            return .alreadyClosed
        case .previousError(let errorState):
            let error = errorState.error
            self = .init(state: .previousError(errorState))
            return .previousError(error)
        }
    }

    @_spi(PackageInternal)
    public enum DecodeNextAction {
        /// A full frame is ready.
        case returnFrame(HTTP3Frame)
        /// An error happened at the connection level.
        case emitConnectionError(HTTP3Error)
        /// An error happened at the stream level.
        case emitStreamError(HTTP3Error)
        /// A frame is ready, but you need to decode it and call the state machine back with the result.
        case decodeHeader(HTTP3PartialFrame.Headers)
        /// The input was already closed
        case alreadyClosed
        /// Input can't be processed further because of a previous error
        case previousError
        /// There is nothing to do for this frame.
        case doNothing

        @_spi(PackageInternal)
        public enum InputClosedAction {
            /// A complete request/response was received before the input was closed. As such, we should just deliver
            /// the `inputClosed` event downstream.
            case emitEvent

            /// A complete response was not received before the input was closed. We need to notify the downstream about
            /// the incompleteness through an error and then deliver the `inputClosed` event.
            case emitErrorAndEvent(HTTP3Error)

            /// A complete request was not received before the input was closed. We need to send a RESET\_STREAM frame.
            case resetStream(HTTP3Error)
        }
    }

    /// Something which arrived whilst we were blocked on a QPACK decode and must be replayed afterwards.
    @_spi(PackageInternal)
    public enum PendingReadAction: Equatable {
        /// Bytes which arrived but couldn't be handed to the frame decoder yet.
        case decodeFrames(ByteBuffer)
        /// A read completion which couldn't be forwarded yet.
        case fireReadComplete
        /// The input was closed.
        case eof
    }

    /// Whether we're currently blocked on a QPACK decode result.
    @_spi(PackageInternal)
    public var isWaitingForHeaderDecode: Bool {
        switch self.state {
        case .idle(let idleState): return idleState.readState.isWaitingForHeaderDecode
        case .finished: return false
        case .previousError: return false
        }
    }

    /// Ask whether `buffer` may be given to the frame decoder right now.
    ///
    /// - Returns: `true` if you should decode the buffer now. `false` if you must not: the bytes were either queued
    ///   inside the state machine, to be replayed via ``gotHeaderDecodeResult(_:)``, or dropped.
    @_spi(PackageInternal)
    public mutating func readyToDecode(_ buffer: ByteBuffer) -> Bool {
        switch self.state {
        case .idle(var idleState):
            let action = idleState.readState.readyToDecode(buffer)
            self = .init(state: .idle(idleState))
            return action

        case .finished:
            self = .init(state: .finished)
            // dropping the buffer is fine
            return false

        case .previousError(let context):
            self = .init(state: .previousError(context))
            return false
        }
    }

    /// Ask whether a read completion may be forwarded downstream right now.
    ///
    /// - Returns: `true` if you should forward it now, `false` if it was queued behind an outstanding QPACK decode.
    @_spi(PackageInternal)
    public mutating func readCompleted() -> Bool {
        switch self.state {
        case .idle(var idleState):
            let action = idleState.readState.readCompleted()
            self = .init(state: .idle(idleState))
            return action

        case .finished:
            self = .init(state: .finished)
            return true

        case .previousError(let context):
            self = .init(state: .previousError(context))
            return true
        }
    }

    /// Queue actions which couldn't be replayed because we became blocked on another QPACK decode.
    @_spi(PackageInternal)
    public mutating func enqueue(_ actions: consuming UniqueDeque<PendingReadAction>) {
        guard !actions.isEmpty else { return }
        switch self.state {
        case .idle(var idleState):
            idleState.readState.enqueue(actions)
            self = .init(state: .idle(idleState))

        case .finished:
            self = .init(state: .finished)

        case .previousError(let context):
            self = .init(state: .previousError(context))
        }
    }

    @_spi(PackageInternal)
    public mutating func decodedFrame(_ frame: HTTP3PartialFrame) -> DecodeNextAction {
        switch self.state {
        case .idle(var idleState):
            let seenEOF = idleState.readState.hasSeenEOF
            let readStateResult = idleState.readState.decodedNext(frame)
            switch readStateResult {
            case .returnFrame(let frame):
                let validationResult = idleState.validator.processInboundFrame(frame)
                switch validationResult {
                case .forwardFrame(let validatedFrame):
                    self = .init(state: .idle(idleState))
                    return .returnFrame(validatedFrame)
                case .emitStreamError(let error):
                    self = .init(state: .previousError(.init(error: error, seenEOF: seenEOF)))
                    return .emitStreamError(error)
                case .emitConnectionError(let error):
                    self = .init(state: .previousError(.init(error: error, seenEOF: seenEOF)))
                    return .emitConnectionError(error)
                case .previousError:
                    self = .init(state: .idle(idleState))
                    return .previousError
                }
            case .returnUnknownFrame:
                self = .init(state: .idle(idleState))
                return self.decodedUnknownFrame()
            case .emitConnectionError(let error):
                self = .init(state: .previousError(.init(error: error, seenEOF: seenEOF)))
                return .emitConnectionError(error)
            case .emitStreamError(let error):
                self = .init(state: .previousError(.init(error: error, seenEOF: seenEOF)))
                return .emitStreamError(error)
            case .decodeHeader(let partialHeader):
                self = .init(state: .idle(idleState))
                return .decodeHeader(partialHeader)
            case .alreadyClosed:
                self = .init(state: .idle(idleState))
                return .alreadyClosed
            case .doNothing:
                self = .init(state: .idle(idleState))
                return .doNothing
            }
        case .finished:
            self = .init(state: .finished)
            return .alreadyClosed
        case .previousError(let error):
            self = .init(state: .previousError(error))
            return .alreadyClosed
        }
    }

    @_spi(PackageInternal)
    public mutating func decodedUnknownFrame() -> DecodeNextAction {
        switch self.state {
        case .idle(var idleState):
            let seenEOF = idleState.readState.hasSeenEOF
            let validationResult = idleState.validator.processInboundUnknownFrame()
            switch validationResult {
            case .emitConnectionError(let error):
                self = .init(state: .previousError(.init(error: error, seenEOF: seenEOF)))
                return .emitConnectionError(error)
            case .dropFrame:
                self = .init(state: .idle(idleState))
                // Unknown frames are simply ignored.
                return .doNothing
            case .previousError:
                self = .init(state: .idle(idleState))
                return .previousError
            }

        case .finished:
            self = .init(state: .finished)
            return .alreadyClosed
        case .previousError(let error):
            self = .init(state: .previousError(error))
            return .alreadyClosed
        }
    }

    /// Inform the state machine that the frame decoder failed to decode the incoming bytes.
    ///
    /// Frame decoding errors are always connection-level errors. No further bytes will be accepted afterwards.
    @_spi(PackageInternal)
    public mutating func frameDecodeError(_ error: HTTP3Error) -> DecodeNextAction {
        switch consume self.state {
        case .idle(let idleState):
            let seenEOF = idleState.readState.hasSeenEOF
            self = .init(state: .previousError(.init(error: error, seenEOF: seenEOF)))
            return .emitConnectionError(error)
        case .finished:
            self = .init(state: .finished)
            return .alreadyClosed
        case .previousError(let context):
            self = .init(state: .previousError(context))
            return .previousError
        }
    }

    @_spi(PackageInternal)
    public struct HeaderDecodeSuccessAction: ~Copyable {
        /// What to do with the now fully decoded HEADERS frame.
        @_spi(PackageInternal)
        public var frameAction: DecodeNextAction

        /// Everything which arrived whilst the decode was outstanding, in arrival order. Empty if ``frameAction``
        /// is an error, because in that case nothing further should be processed.
        var nextActions: UniqueDeque<PendingReadAction>

        /// Take ownership of the queued replay actions.
        ///
        /// This exists because ``nextActions`` is noncopyable, and a noncopyable field can only be moved out of a
        /// struct within the module that declares it.
        @_spi(PackageInternal)
        public consuming func takeNextActions() -> UniqueDeque<PendingReadAction> {
            self.nextActions
        }
    }

    /// Inform the state machine of a qpack decode result that has been previously been asked for.
    /// It is an error to call this function with a result for a partial header which wasn't asked for.
    @_spi(PackageInternal)
    public mutating func gotHeaderDecodeResult(_ decoded: [HTTPField]) -> HeaderDecodeSuccessAction? {
        switch self.state {
        case .finished:
            // Ignore it, we don't care anymore
            self = .init(state: .finished)
            return nil
        case .idle(var idleState):
            let seenEOF = idleState.readState.hasSeenEOF
            let pending = idleState.readState.gotHeaderDecodeResult()
            // The header section is only now a complete frame, so this is the point at which the validator sees it.
            switch idleState.validator.processInboundFrame(.headers(.init(fields: decoded))) {
            case .forwardFrame(let validatedFrame):
                self = .init(state: .idle(idleState))
                return .init(frameAction: .returnFrame(validatedFrame), nextActions: pending)
            case .emitStreamError(let error):
                self = .init(state: .previousError(.init(error: error, seenEOF: seenEOF)))
                return .init(frameAction: .emitStreamError(error), nextActions: .init())
            case .emitConnectionError(let error):
                self = .init(state: .previousError(.init(error: error, seenEOF: seenEOF)))
                return .init(frameAction: .emitConnectionError(error), nextActions: .init())
            case .previousError:
                self = .init(state: .idle(idleState))
                return .init(frameAction: .previousError, nextActions: .init())
            }
        case .previousError(let error):
            self = .init(state: .previousError(error))
            return nil
        }
    }

    @_spi(PackageInternal)
    public struct HeaderDecodeFailureAction {
        @_spi(PackageInternal)
        public var error: HTTP3Error
    }

    /// Inform the state machine of a qpack decode error for a header that the machine previously asked to decode.
    /// It is an error to call this function with a result for a partial header which wasn't asked for.
    /// This error will fail the stream. Connection-level errors should not be sent here.
    @_spi(PackageInternal)
    public mutating func gotHeaderDecodeError(_ error: HTTP3Error) -> HeaderDecodeFailureAction? {
        switch self.state {
        case .finished:
            // Ignore it, we don't care anymore
            self = .init(state: .finished)
            return nil
        case .idle(var idleState):
            let seenEOF = idleState.readState.hasSeenEOF
            let wasWaiting = idleState.readState.gotHeaderDecodeError()
            self = .init(state: .previousError(.init(error: error, seenEOF: seenEOF)))
            return wasWaiting ? HeaderDecodeFailureAction(error: error) : nil
        case .previousError(let error):
            self = .init(state: .previousError(error))
            return nil
        }
    }

    /// Inform the state machine that there is nothing left to read.
    ///
    /// - Note: You should flush the frame decoder before calling this, so that any remaining frames are pushed in
    ///   first. Check ``isWaitingForHeaderDecode`` before doing so: if we're blocked on a QPACK decode, the closure is
    ///   queued and replayed later instead.
    /// - Returns: The action to take, or `nil` if there is nothing to do right now.
    @_spi(PackageInternal)
    public mutating func inputClosed() -> DecodeNextAction.InputClosedAction? {
        switch consume self.state {
        case .finished:
            // Why are we getting input closed after already closed?
            assertionFailure("Input closed after stream closed")
            self = .init(state: .finished)
            return nil
        case .previousError(let error):
            self = .init(state: .previousError(error))
            return nil
        case .idle(var idleState):
            guard idleState.readState.inputClosed() else {
                // Queued behind an outstanding QPACK decode, or already closed.
                self = .init(state: .idle(idleState))
                return nil
            }
            // The input was closed. Inform the validator to determine what to do next.
            switch idleState.validator.processInboundClosed() {
            case .doNothing:
                self = .init(state: .idle(idleState))
                return .emitEvent

            case .notifyDownstream(let error):
                self = .init(state: .idle(idleState))
                return .emitErrorAndEvent(error)

            case .resetStream(let error):
                self = .init(state: .previousError(.init(error: error, seenEOF: true)))
                return .resetStream(error)
            }
        }
    }

    @_spi(PackageInternal)
    public enum ErrorCaughtAction {
        case emitStreamError(HTTP3Error)
    }

    /// Inform the state machine of a stream error which was caught on this stream.
    @_spi(PackageInternal)
    public mutating func streamErrorCaught(errorCode: QUICApplicationErrorCode) -> ErrorCaughtAction? {
        // Preserve the peer's error code verbatim for reporting, even if it is
        // not one this library recognizes. The reaction is a generic stream
        // error (`.remoteStreamError`), which already satisfies RFC 9114 § 8's
        // requirement to treat an unknown code as equivalent to H3_NO_ERROR.
        let errorCodeValue = HTTP3ErrorCode(rawValue: errorCode.rawValue)
        @inline(never)
        func remoteStreamError(
            errorCode: HTTP3ErrorCode,
            location: HTTP3Error.SourceLocation
        ) -> HTTP3Error {
            HTTP3Error(
                code: .remoteStreamError,
                message: "The remote peer closed the stream",
                cause: nil,
                errorCode: errorCode,
                location: location
            )
        }
        switch consume self.state {
        case .idle(let idleState):
            let error = remoteStreamError(errorCode: errorCodeValue, location: .here())
            self = .init(state: .previousError(.init(error: error, seenEOF: idleState.readState.hasSeenEOF)))
            return .emitStreamError(error)
        case .previousError(let previousError):
            // ignore the new error because we already are in an error state
            self = .init(state: .previousError(previousError))
            return nil
        case .finished:
            // Errors are irrelevant now
            self = .init(state: .finished)
            return nil
        }
    }

    @_spi(PackageInternal)
    public enum FinishedAction: Hashable, Sendable {
        /// The stream has been closed. If `seenEOF` is false, then we potentially dropped incoming data.
        case streamClosed(seenEOF: Bool)
    }

    /// Inform the state machine that the stream is no longer open.
    /// - Note: You should flush the frame decoder to unbuffer as much as possible before calling this function.
    @_spi(PackageInternal)
    public mutating func closed() -> FinishedAction? {
        switch consume self.state {
        case .idle(let idle):
            let finishState = idle.readState.closed()
            self = .init(state: .finished)

            switch finishState {
            case .sawEOF:
                return .streamClosed(seenEOF: true)

            case .noEOF:
                return .streamClosed(seenEOF: false)
            }
        case .previousError(let errorState):
            let seenEOF = errorState.seenEOF
            self = .init(state: .finished)
            return .streamClosed(seenEOF: seenEOF)

        case .finished:
            assertionFailure("Finished called twice")
            self = .init(state: .finished)
            return nil
        }
    }
}

/// A HTTP3Frame can be made into a HTTP3PartialFrame trivially, if it is not headers or push promise. This enum represents those 3 possibilities.
private enum MaybePartialFrame {
    /// The frame is headers.
    case headers(HTTP3Frame.Headers)
    /// The frame is a push promise.
    case pushPromise(HTTP3Frame.PushPromise)
    /// The frame is not headers nor push promise, and therefore can be represented as a ``HTTP3PartialFrame``.
    case partial(HTTP3PartialFrame)

    init(_ full: HTTP3Frame) {
        switch full {
        case .headers(let partialHeaders): self = .headers(partialHeaders)
        case .data(let data): self = .partial(.data(data))
        case .settings(let settings): self = .partial(.settings(settings))
        case .goaway(let goaway): self = .partial(.goaway(goaway))
        case .maxPushID(let maxPushID): self = .partial(.maxPushID(maxPushID))
        case .pushPromise(let pushPromise): self = .pushPromise(pushPromise)
        case .cancelPush(let cancelPush): self = .partial(.cancelPush(cancelPush))
        }
    }
}

extension HTTP3PartialFrame {
    /// Turn a partial frame into a full frame as long as it's not a header or push promise frame.
    ///
    /// Header frames and push promise frames must go through a QPACK decoder.
    /// It is a fatal error to call this function on a ``HTTP3Frame/headers(_:)`` or ``HTTP3Frame/pushPromise(_:)``.
    fileprivate func asFullFrameNotHeadersOrPush() -> HTTP3Frame {
        switch self {
        case .headers: fatalError("Cannot unwrap headers")
        case .pushPromise: fatalError("Cannot unwrap push promise")
        case .data(let data): return .data(data)
        case .settings(let settings): return .settings(settings)
        case .goaway(let goaway): return .goaway(goaway)
        case .maxPushID(let maxPushID): return .maxPushID(maxPushID)
        case .cancelPush(let cancelPush): return .cancelPush(cancelPush)
        }
    }
}
