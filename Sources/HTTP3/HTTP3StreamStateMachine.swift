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

package import HTTPTypes

package import struct NIOCore.ByteBuffer
package import struct NIOQUICHelpers.QUICApplicationErrorCode

package struct HTTP3StreamStateMachine: ~Copyable {
    /// This state machine handles the reading side of the stream only.
    /// You call `buffer` to give it bytes, and continually call `decodeNext` to get out frames.
    /// Sometimes, decodeNext will return the `decodeHeader` action, in which case you need to decode those headers.
    /// and call gotHeaderDecodeResult. Further frames will be blocked behind that, to maintain the order.
    struct ReadState: ~Copyable {
        private enum State: ~Copyable {
            /// Nothing special is happening on the read side.
            case idle(Idle)

            /// We have read a partial header. We can't take further frames out of the decoder state machine until this header is decoded.
            case waitingForDecode(WaitingForDecode)

            /// We previously read a partial header. It's now decoded and we know the frame. We can't read further out of the frame decoder until this buffered frame is sent.
            case buffered(Buffered)

            /// We previously read a partial header. We asked for it to be decoded, and got back an error. We'll return this error on the next decodeNext call.
            case headerDecodeError(HeaderDecodeError)

            /// Input is closed, we can receive no more.
            case inputClosed

            struct Idle: ~Copyable {
                var decoder: HTTP3FrameDecoderStateMachine
                /// If we receive a close whilst waiting for a decode, we buffer it here. We must maintain the order of closes relative to reads.
                var seenEOF: Bool
            }

            struct WaitingForDecode: ~Copyable {
                var decoder: HTTP3FrameDecoderStateMachine
                let partialHeader: HTTP3PartialFrame.Headers
                /// If we receive a close whilst waiting for a decode, we buffer it here. We must maintain the order of closes relative to reads.
                var seenEOF: Bool

                init(idleState: consuming Idle, partialHeader: HTTP3PartialFrame.Headers) {
                    self.decoder = idleState.decoder
                    self.partialHeader = partialHeader
                    self.seenEOF = idleState.seenEOF
                }
            }

            struct Buffered: ~Copyable {
                var decoder: HTTP3FrameDecoderStateMachine
                let frame: HTTP3Frame
                /// If we receive a close whilst waiting for a decode, we buffer it here. We must maintain the order of closes relative to reads.
                var seenEOF: Bool

                init(waitingState: consuming WaitingForDecode, frame: HTTP3Frame) {
                    self.decoder = waitingState.decoder
                    self.frame = frame
                    self.seenEOF = waitingState.seenEOF
                }
            }

            struct HeaderDecodeError {
                let error: HTTP3Error
                /// If we receive a close whilst waiting for a decode, we buffer it here. We must maintain the order of closes relative to reads.
                var seenEOF: Bool
            }
        }

        private let state: State

        init(decoder: consuming HTTP3FrameDecoderStateMachine) {
            self.init(state: .idle(.init(decoder: decoder, seenEOF: false)))
        }

        private init(state: consuming State) {
            self.state = state
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
            /// The input is newly closed, nothing else will come now. This action should only be seen once
            case inputClosed
            /// There is no action because the input was already closed.
            case alreadyClosed
            /// More bytes are needed to form the next frame
            case needMoreBytes
            /// We are blocked on a header section being decoded. New bytes won't unblock this - only new QPACK instructions can
            case needDecodeResult
        }

        /// Read out the next frame if it is ready. This may ask you to run qpack on some partial headers.
        mutating func decodeNext() -> DecodeNextAction {
            switch consume self.state {
            case .idle(var idleState):
                let decodedResult = idleState.decoder.decodeNext()
                switch decodedResult {
                case .emitConnectionError(let error):
                    self = .init(state: .idle(idleState))
                    return .emitConnectionError(error)
                case .previousError:
                    // we already emitted this error.
                    self = .init(state: .idle(idleState))
                    // This is the same as the input being closed because we won't decode anything further now.
                    return .alreadyClosed
                case .needMoreBytes:
                    if idleState.seenEOF {
                        // There is no more input (we have seen EOF) and the decoder is not able to make any more frames (it returned .needMoreBytes)
                        // We need to check whether the decoder has any leftover bytes.
                        let hasLeftoverBytes = idleState.decoder.inputClosed()
                        if hasLeftoverBytes {
                            // RFC 9214 § 7.1 When a stream terminates cleanly, if the last frame on the stream was truncated, this MUST be treated as a connection error of type H3_FRAME_ERROR.
                            // Streams that terminate abruptly may be reset at any point in a frame.
                            @inline(never)
                            func uncleanStateError(location: HTTP3Error.SourceLocation) -> HTTP3Error {
                                HTTP3Error(
                                    code: .leftoverBytes,
                                    message: "There were leftover bytes when the input was closed",
                                    cause: nil,
                                    errorCode: .frameError,
                                    location: location
                                )
                            }
                            self = .init(state: .inputClosed)
                            return .emitConnectionError(uncleanStateError(location: .here()))
                        } else {
                            // There are no leftover bytes, so we close and all is well.
                            self = .init(state: .inputClosed)
                            return .inputClosed
                        }
                    } else {
                        // The decoder is not able to make a complete frame. That's fine, we'll just wait for more bytes.
                        self = .init(state: .idle(idleState))
                        return .needMoreBytes
                    }
                case .returnFrame(.headers(let partialHeader)):
                    self = .init(
                        state: .waitingForDecode(.init(idleState: idleState, partialHeader: partialHeader))
                    )
                    return .decodeHeader(partialHeader)
                case .returnFrame(.pushPromise):
                    self = .init(state: .idle(idleState))
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
                case .returnFrame(let frame):
                    self = .init(state: .idle(idleState))
                    return .returnFrame(frame.asFullFrameNotHeadersOrPush())
                case .returnUnknownFrame:
                    self = .init(state: .idle(idleState))
                    return .returnUnknownFrame
                }
            case .waitingForDecode(let waitingState):
                self = .init(state: .waitingForDecode(waitingState))
                return .needDecodeResult
            case .buffered(let bufferState):
                self = .init(state: .idle(.init(decoder: bufferState.decoder, seenEOF: bufferState.seenEOF)))
                return .returnFrame(bufferState.frame)
            case .headerDecodeError(let error):
                self = .init(state: .inputClosed)
                return .emitStreamError(error.error)
            case .inputClosed:
                self = .init(state: .inputClosed)
                return .alreadyClosed
            }
        }

        /// Inform the state machine of a qpack decode result that has been previously been asked for.
        /// It is an error to call this function with a result for a partial header which wasn't asked for.
        mutating func gotHeaderDecodeResult(_ decoded: [HTTPField], from: HTTP3PartialFrame.Headers) {
            switch consume self.state {
            case .waitingForDecode(let waitingState):
                guard waitingState.partialHeader == from else {
                    fatalError("Called gotHeaderDecodeResult with wrong partial header")
                }
                self = .init(
                    state: .buffered(
                        .init(
                            waitingState: waitingState,
                            frame: .headers(.init(fields: decoded))
                        )
                    )
                )
            case .buffered:
                fatalError("Unexpected header decode")
            case .idle:
                fatalError("Unexpected header decode")
            case .headerDecodeError:
                fatalError("Unexpected header decode")
            case .inputClosed:
                fatalError("Unexpected header decode")
            }
        }

        /// Inform the state machine of a qpack decode error for a header that the machine previously asked to decode.
        /// It is an error to call this function with a result for a partial header which wasn't asked for.
        mutating func gotHeaderDecodeError(_ error: HTTP3Error, from: HTTP3PartialFrame.Headers) {
            switch consume self.state {
            case .idle:
                fatalError("Unexpected header decode")
            case .buffered:
                fatalError("Unexpected header decode")
            case .headerDecodeError:
                fatalError("Unexpected header decode")
            case .inputClosed:
                fatalError("Unexpected header decode")
            case .waitingForDecode(let waitingState):
                guard waitingState.partialHeader == from else {
                    fatalError("Called gotHeaderDecodeError with wrong partial header")
                }
                self = .init(state: .headerDecodeError(.init(error: error, seenEOF: waitingState.seenEOF)))
            }
        }

        /// Although this is the reading state, we might want to prevent writes happening based on the read state.
        /// - Returns: True if writes should be allowed. Otherwise, they should be dropped.
        func checkCanWrite() -> Bool {
            switch self.state {
            case .headerDecodeError:
                // We failed to decode an incoming header. We haven't emitted that error yet
                // But the stream is doomed to fail, so we can drop this write
                // We'll not emit the error here, that will happen on decodeNext()
                return false
            case .idle:
                return true
            case .buffered:
                return true
            case .waitingForDecode:
                return true
            case .inputClosed:
                return true
            }
        }

        mutating func buffer(_ buffer: ByteBuffer) {
            // Regardless of the current state, buffer the bytes into the decoder
            switch self.state {
            case .idle(var idleState):
                idleState.decoder.buffer(buffer)
                self = .init(state: .idle(idleState))
            case .waitingForDecode(var waitingState):
                waitingState.decoder.buffer(buffer)
                self = .init(state: .waitingForDecode(waitingState))
            case .buffered(var bufferState):
                bufferState.decoder.buffer(buffer)
                self = .init(state: .buffered(bufferState))
            case .headerDecodeError(let errorState):
                // We'll emit the header decode error on decodeNext. Can drop the new bytes
                self = .init(state: .headerDecodeError(errorState))
            case .inputClosed:
                self = .init(state: .inputClosed)
            }
        }

        /// Call this when there is nothing left to read. The inputClose will get queued behind any buffered incoming frames.
        mutating func inputClosed() {
            switch consume self.state {
            case .buffered(var buffered):
                buffered.seenEOF = true
                self = .init(state: .buffered(buffered))
            case .waitingForDecode(var buffered):
                buffered.seenEOF = true
                self = .init(state: .waitingForDecode(buffered))
            case .headerDecodeError(var buffered):
                buffered.seenEOF = true
                self = .init(state: .headerDecodeError(buffered))
            case .idle(var idle):
                idle.seenEOF = true
                self = .init(state: .idle(idle))
            case .inputClosed:
                // TODO: Should this be an error?
                self = .init(state: .inputClosed)
            }
        }

        package enum FinishType {
            /// We had seen EOF before the close.
            case sawEOF
            /// We hadn't seen EOF before the close.
            case noEOF
        }

        /// Call this when the stream is completely closed. This will tell you whether or not we saw an EOF, i.e. any frames were potentially dropped.
        /// This function is consuming, the state machine can't be used after closing.
        /// - Note: You should ``decodeNext()`` as much as possible before calling this.
        consuming func closed() -> FinishType {
            switch consume self.state {
            case .buffered:
                return .noEOF
            case .waitingForDecode:
                return .noEOF
            case .headerDecodeError:
                return .noEOF
            case .idle:
                // This is unclean even if we have seen EOF. That is because we haven't unbuffered the EOF.
                // That is why it's important to decode as much as possible before calling finished()
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
        case previousError(HTTP3Error)

        /// The stream is closed.
        case finished
        struct Idle: ~Copyable {
            var validator: HTTP3FrameValidator
            var readState: ReadState
            var writeState: WriteState
        }
    }

    private let state: State

    package init(
        streamType: HTTP3StreamType.Framed,
        incoming: Bool,
        preferHuffmanEncoding: Bool
    ) {
        let frameDecoder = HTTP3FrameDecoderStateMachine()
        let frameValidator = HTTP3FrameValidator(streamType: streamType, incoming: incoming)
        let readState = ReadState(decoder: frameDecoder)
        let writeState = WriteState(preferHuffmanEncoding: preferHuffmanEncoding)
        self.init(state: .idle(.init(validator: frameValidator, readState: readState, writeState: writeState)))
    }

    private init(state: consuming State) {
        self.state = state
    }

    package enum WriteFrameAction {
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
    package mutating func writeFrame(frame: HTTP3Frame, into buffer: inout ByteBuffer) -> WriteFrameAction {
        switch self.state {
        case .idle(var idleState):
            guard idleState.readState.checkCanWrite() else {
                self = .init(state: .idle(idleState))
                return .previousError
            }
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
                self = .init(state: .previousError(error))
                return .wouldBeStreamError(error)
            case .emitConnectionError(let error):
                self = .init(state: .previousError(error))
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

    package enum HeaderEncodeResultAction {
        /// The header's bytes were appended to the buffer you provided.
        case wroteBytes
        /// This header can't be encoded because the stream is already in an error state.
        case previousError(HTTP3Error)
        /// You should fail the current write because the stream is already closed
        case alreadyClosed
    }

    package mutating func gotHeaderEncodeResult(
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
        case .previousError(let error):
            self = .init(state: .previousError(error))
            return .previousError(error)
        }
    }

    /// Tell the machine about incoming bytes.
    package mutating func buffer(_ buffer: ByteBuffer) {
        // Buffer the bytes into the decoder as long as we didn't already hit an error
        switch self.state {
        case .idle(var idleState):
            idleState.readState.buffer(buffer)
            self = .init(state: .idle(idleState))
        case .previousError(let error):
            self = .init(state: .previousError(error))
        case .finished:
            // Drop the new bytes because we already closed
            self = .init(state: .finished)
        }
    }

    package enum DecodeNextAction {
        /// A full frame is ready.
        case returnFrame(HTTP3Frame)
        /// An error happened at the connection level.
        case emitConnectionError(HTTP3Error)
        /// An error happened at the stream level.
        case emitStreamError(HTTP3Error)
        /// A frame is ready, but you need to decode it and call the state machine back with the result.
        case decodeHeader(HTTP3PartialFrame.Headers)
        /// The input was newly closed.
        case inputClosed
        /// The input was already closed
        case alreadyClosed
        /// More input is needed before the next action can be determined
        case needMoreBytes
        /// Input can't be processed further because of a previous error
        case previousError
        /// The decodeNext() function should be called again to get the next action.
        case callAgain
    }

    /// Read out the next frame if it is ready. This may ask you to run qpack on some partial headers.
    ///
    /// - Returns: The next action to be performed.
    package mutating func decodeNext() -> DecodeNextAction {
        switch self.state {
        case .idle(var idleState):
            let readStateResult = idleState.readState.decodeNext()
            switch readStateResult {
            case .returnFrame(let frame):
                let validationResult = idleState.validator.processInboundFrame(frame)
                switch validationResult {
                case .forwardFrame(let validatedFrame):
                    self = .init(state: .idle(idleState))
                    return .returnFrame(validatedFrame)
                case .emitStreamError(let error):
                    self = .init(state: .previousError(error))
                    return .emitStreamError(error)
                case .emitConnectionError(let error):
                    self = .init(state: .previousError(error))
                    return .emitConnectionError(error)
                case .previousError:
                    self = .init(state: .idle(idleState))
                    return .previousError
                }
            case .returnUnknownFrame:
                let validationResult = idleState.validator.processInboundUnknownFrame()
                switch validationResult {
                case .emitConnectionError(let error):
                    self = .init(state: .previousError(error))
                    return .emitConnectionError(error)
                case .dropFrame:
                    self = .init(state: .idle(idleState))
                    // We received a frame which we want to drop.
                    // We need to get the _next_ action. Which might be needMoreBytes, or we might already have the next frame.
                    return .callAgain
                case .previousError:
                    self = .init(state: .idle(idleState))
                    return .previousError
                }
            case .emitConnectionError(let error):
                self = .init(state: .previousError(error))
                return .emitConnectionError(error)
            case .emitStreamError(let error):
                self = .init(state: .previousError(error))
                return .emitStreamError(error)
            case .decodeHeader(let partialHeader):
                self = .init(state: .idle(idleState))
                return .decodeHeader(partialHeader)
            case .alreadyClosed:
                self = .init(state: .idle(idleState))
                return .alreadyClosed
            case .needDecodeResult, .needMoreBytes:
                self = .init(state: .idle(idleState))
                return .needMoreBytes
            case .inputClosed:
                self = .init(state: .idle(idleState))
                return .inputClosed
            }
        case .finished:
            self = .init(state: .finished)
            return .alreadyClosed
        case .previousError(let error):
            self = .init(state: .previousError(error))
            return .alreadyClosed
        }
    }

    /// Inform the state machine of a qpack decode result that has been previously been asked for.
    /// It is an error to call this function with a result for a partial header which wasn't asked for.
    package mutating func gotHeaderDecodeResult(_ decoded: [HTTPField], from: HTTP3PartialFrame.Headers) {
        switch self.state {
        case .finished:
            // Ignore it, we don't care anymore
            self = .init(state: .finished)
        case .idle(var idleState):
            idleState.readState.gotHeaderDecodeResult(decoded, from: from)
            self = .init(state: .idle(idleState))
        case .previousError(let error):
            self = .init(state: .previousError(error))
        }
    }

    /// Inform the state machine of a qpack decode error for a header that the machine previously asked to decode.
    /// It is an error to call this function with a result for a partial header which wasn't asked for.
    /// This error will fail the stream. Connection-level errors should not be sent here.
    package mutating func gotHeaderDecodeError(_ error: HTTP3Error, from: HTTP3PartialFrame.Headers) {
        switch self.state {
        case .finished:
            // Ignore it, we don't care anymore
            self = .init(state: .finished)
        case .idle(var idleState):
            idleState.readState.gotHeaderDecodeError(error, from: from)
            self = .init(state: .idle(idleState))
        case .previousError(let error):
            self = .init(state: .previousError(error))
        }
    }

    package mutating func inputClosed() {
        switch consume self.state {
        case .finished:
            // Why are we getting input closed after already closed?
            assertionFailure("Input closed after stream closed")
            self = .init(state: .finished)
        case .previousError(let error):
            self = .init(state: .previousError(error))
        case .idle(var idleState):
            idleState.readState.inputClosed()
            self = .init(state: .idle(idleState))
        }
    }

    package enum ErrorCaughtAction {
        case emitStreamError(HTTP3Error)
    }

    /// Inform the state machine of a stream error which was caught on this stream.
    package mutating func streamErrorCaught(errorCode: QUICApplicationErrorCode) -> ErrorCaughtAction? {
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
        case .idle:
            let error = remoteStreamError(errorCode: errorCodeValue, location: .here())
            self = .init(state: .previousError(error))
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

    package enum FinishedAction: Hashable, Sendable {
        /// The stream has been closed. If `seenEOF` is false, then we potentially dropped incoming data.
        case streamClosed(seenEOF: Bool)
    }

    /// Inform the state machine that the stream is no longer open.
    /// - Note: You should call ``decodeNext()`` to unbuffer as much as possible before calling this function.
    package mutating func closed() -> FinishedAction {
        switch consume self.state {
        case .idle(let idle):
            let finishState = idle.readState.closed()
            self = .init(state: .finished)
            switch finishState {
            case .sawEOF: return .streamClosed(seenEOF: true)
            case .noEOF: return .streamClosed(seenEOF: false)
            }
        case .previousError:
            self = .init(state: .finished)
            return .streamClosed(seenEOF: false)
        case .finished:
            fatalError("Finished called twice")
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
