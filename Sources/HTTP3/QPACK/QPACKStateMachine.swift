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

package import DequeModule
package import HTTPTypes
import Logging
package import NIOQUICHelpers
package import QPACK

/// A state machine which holds qpack encoder and decoder.
/// You can ask it to encode/decode things, and inform it of incoming instructions.
/// It will then return actions to be taken.
package struct QPACKStateMachine: ~Copyable {
    struct EncoderStateMachine: ~Copyable {
        private enum State: ~Copyable {
            /// The remote side has not yet told us what dynamic table size to use, so we must assume 0, ie use a static encoder.
            case initial(Initial)

            /// The remote side has indicated that it does want to use the dynamic table, but we haven't created an encoder stream yet, so we can't send any instructions. So we still have to use static encoding only.
            /// We remember the remotes settings, so that we can switch to dynamic once the stream is ready.
            case awaitingStream(AwaitingStream)

            /// We can use the dynamic table now.
            case withDynamic(WithDynamic)

            /// The remote side has told us not to use dynamic table. We will never open an encoder stream, and we'll always use the static encoder.
            case withoutDynamic(WithoutDynamic)

            struct Initial: ~Copyable {
                var encoder: StaticQPACKEncoder
            }

            struct AwaitingStream: ~Copyable {
                var encoder: StaticQPACKEncoder
                let maxQueueSize: Int
                let dynamicTableSize: Int
            }

            struct WithDynamic: ~Copyable {
                var encoder: DynamicQPACKEncoder
            }

            struct WithoutDynamic: ~Copyable {
                var encoder: StaticQPACKEncoder
            }
        }

        private let state: State
        private let localMaxTableCapacity: Int

        private init(state: consuming State, localMaxTableCapacity: Int) {
            self.state = state
            self.localMaxTableCapacity = localMaxTableCapacity
        }

        init(localMaxTableCapacity: Int) {
            self.init(state: .initial(.init(encoder: .init())), localMaxTableCapacity: localMaxTableCapacity)
        }

        mutating func receivedRemoteSettings(
            maxQueueSize: Int,
            dynamicTableSize: Int
        ) -> GotRemoteSettingsAction? {
            let localMaxTableCapacity = self.localMaxTableCapacity
            switch consume self.state {
            case .initial(let initial):
                // RFC 9204 § 4.2: An endpoint MAY avoid creating an encoder stream if it will not be used
                // This should include if the local table will not be used either
                if dynamicTableSize == 0 || localMaxTableCapacity == 0 {
                    self = .init(
                        state: .withoutDynamic(
                            .init(encoder: initial.encoder)
                        ),
                        localMaxTableCapacity: localMaxTableCapacity
                    )
                    return nil
                } else {
                    self = .init(
                        state: .awaitingStream(
                            .init(
                                encoder: initial.encoder,
                                maxQueueSize: maxQueueSize,
                                dynamicTableSize: dynamicTableSize
                            )
                        ),
                        localMaxTableCapacity: localMaxTableCapacity
                    )
                    return .makeEncoderInstructionStream
                }
            case .awaitingStream:
                // This can't happen because the frame validator enforces only one settings frame
                fatalError("Double remote settings")
            case .withDynamic:
                // This can't happen because the frame validator enforces only one settings frame
                fatalError("Double remote settings")
            case .withoutDynamic:
                // This can't happen because the frame validator enforces only one settings frame
                fatalError("Double remote settings")
            }
        }

        enum OutboundEncoderStreamReadyAction {
            case sendEncoderInstruction(QPACKEncoderInstruction?)
        }

        mutating func outboundEncoderStreamReady() -> OutboundEncoderStreamReadyAction {
            let localMaxTableCapacity = self.localMaxTableCapacity
            switch consume self.state {
            case .initial:
                fatalError("Encoder stream created when not needed or already made")
            case .withoutDynamic:
                fatalError("Encoder stream created when not needed or already made")
            case .withDynamic:
                fatalError("Encoder stream created when not needed or already made")
            case .awaitingStream(let awaitingStream):
                let (dynamicEncoder, instruction) = DynamicQPACKEncoder.create(
                    dynamicTableMaxCapacity: awaitingStream.dynamicTableSize,
                    dynamicTableInitialCapacity: awaitingStream.dynamicTableSize,
                    maxBlockedStreams: awaitingStream.maxQueueSize,
                    targetEvictableFraction: QPACKConstants.defaultTargetEvictableFraction
                )
                self = .init(
                    state: .withDynamic(
                        .init(
                            encoder: dynamicEncoder
                        )
                    ),
                    localMaxTableCapacity: localMaxTableCapacity
                )
                return .sendEncoderInstruction(instruction)
            }
        }

        mutating func encodeHeaders(_ headers: [HTTPField], forStream streamID: QUICStreamID) -> QPACKEncodeResult {
            let localMaxTableCapacity = self.localMaxTableCapacity
            switch consume self.state {
            case .initial(let initial):
                let result = QPACKEncodeResult(fieldSection: initial.encoder.encode(headers: headers), instructions: [])
                self = .init(state: .initial(initial), localMaxTableCapacity: localMaxTableCapacity)
                return result
            case .awaitingStream(let awaiting):
                let result = QPACKEncodeResult(
                    fieldSection: awaiting.encoder.encode(headers: headers),
                    instructions: []
                )
                self = .init(state: .awaitingStream(awaiting), localMaxTableCapacity: localMaxTableCapacity)
                return result
            case .withoutDynamic(let woDynamic):
                let result = QPACKEncodeResult(
                    fieldSection: woDynamic.encoder.encode(headers: headers),
                    instructions: []
                )
                self = .init(state: .withoutDynamic(woDynamic), localMaxTableCapacity: localMaxTableCapacity)
                return result
            case .withDynamic(var withDynamic):
                let result = withDynamic.encoder.encode(headers: headers, forStream: streamID)
                self = .init(state: .withDynamic(withDynamic), localMaxTableCapacity: localMaxTableCapacity)
                return result
            }
        }

        enum IncomingDecoderInstructionAction {
            case emitConnectionError(HTTP3Error)
        }

        fileprivate mutating func receivedIncomingDecoderInstruction(
            _ instruction: QPACKDecoderInstruction
        ) -> IncomingDecoderInstructionAction? {
            @inline(never)
            func noDynamicTableError(location: HTTP3Error.SourceLocation) -> HTTP3Error {
                HTTP3Error(
                    code: .qpackDecoderStreamError,
                    message: "Decoder instruction received when dynamic table not being used",
                    cause: nil,
                    errorCode: .QPACK_DECODER_STREAM_ERROR,
                    location: location
                )
            }
            let localMaxTableCapacity = self.localMaxTableCapacity
            switch consume self.state {
            case .initial(let initial):
                self = .init(state: .initial(initial), localMaxTableCapacity: localMaxTableCapacity)
                return .emitConnectionError(noDynamicTableError(location: .here()))
            case .awaitingStream(let awaitingStream):
                self = .init(state: .awaitingStream(awaitingStream), localMaxTableCapacity: localMaxTableCapacity)
                return .emitConnectionError(noDynamicTableError(location: .here()))
            case .withoutDynamic(let withoutDynamic):
                self = .init(state: .withoutDynamic(withoutDynamic), localMaxTableCapacity: localMaxTableCapacity)
                return .emitConnectionError(noDynamicTableError(location: .here()))
            case .withDynamic(var withDynamic):
                do {
                    try withDynamic.encoder.processInstruction(instruction)
                    self = .init(state: .withDynamic(withDynamic), localMaxTableCapacity: localMaxTableCapacity)
                    return nil
                } catch {
                    @inline(never)
                    func invalidDecoderInstructionError(
                        cause: any Error,
                        location: HTTP3Error.SourceLocation
                    ) -> HTTP3Error {
                        HTTP3Error(
                            code: .qpackDecoderStreamError,
                            message: "Invalid decoder instruction",
                            cause: cause,
                            errorCode: .QPACK_DECODER_STREAM_ERROR,
                            location: location
                        )
                    }
                    // TODO: move to error state?
                    self = .init(state: .withDynamic(withDynamic), localMaxTableCapacity: localMaxTableCapacity)
                    return .emitConnectionError(invalidDecoderInstructionError(cause: error, location: .here()))
                }
            }
        }
    }

    /// We are initially in a queued state because we buffer all outgoing instructions until the stream is ready.
    /// Once the stream is ready, we can send the buffered instructions.
    /// Further instructions after that can be sent without buffering.
    struct OutboundDecoderInstructionQueue: ~Copyable {
        enum State: ~Copyable {
            case queued(Queued)
            case noQueue

            struct Queued: ~Copyable {
                var instructionQueue: Deque<QPACKDecoderInstruction>
            }
        }

        private let state: State

        private init(state: consuming State) {
            self.state = state
        }

        init() {
            self.init(state: .queued(.init(instructionQueue: .init())))
        }

        enum OutboundDecoderStreamReadyAction {
            case sendDecoderInstructions(Deque<QPACKDecoderInstruction>)
        }

        mutating func outboundDecoderStreamReady() -> OutboundDecoderStreamReadyAction? {
            switch consume self.state {
            case .noQueue:
                // There is already no queue, means outboundDecoderStreamReady was already called
                fatalError("outboundDecoderStreamReady called twice")
            case .queued(let queued):
                // We currently have a queue. We can flush the queue and move to the noQueue state
                self = .init(state: .noQueue)
                if queued.instructionQueue.isEmpty {
                    return nil
                }
                return .sendDecoderInstructions(queued.instructionQueue)
            }
        }

        enum WriteDecoderInstructionAction {
            case sendDecoderInstruction(QPACKDecoderInstruction)
        }

        mutating func writeDecoderInstruction(
            _ instruction: QPACKDecoderInstruction?
        ) -> WriteDecoderInstructionAction? {
            guard let instruction else { return nil }
            switch consume self.state {
            case .noQueue:
                // There is no queue, the stream is already ready. We can simply write out
                self = .init(state: .noQueue)
                return .sendDecoderInstruction(instruction)
            case .queued(var queued):
                // The stream is not ready, we must buffer
                queued.instructionQueue.append(instruction)
                self = .init(state: .queued(queued))
                return nil
            }
        }
    }

    private var encoderState: EncoderStateMachine
    private var qpackDecoder: QPACKDecoder
    private var decoderQueue: FieldSectionQueue
    private var outboundDecoderInstructionQueue: OutboundDecoderInstructionQueue

    package init(decoderMaxTableSize: Int, decoderMaxBlockedStreams: Int, localEncoderMaxTableCapacity: Int = 0) {
        self.encoderState = .init(localMaxTableCapacity: localEncoderMaxTableCapacity)
        self.qpackDecoder = .init(dynamicTableMaxCapacity: decoderMaxTableSize)
        self.decoderQueue = .init(maxItems: decoderMaxBlockedStreams)
        self.outboundDecoderInstructionQueue = .init()
    }

    package enum GotRemoteSettingsAction {
        case makeEncoderInstructionStream
    }

    /// Call this when the settings have been received from the remote. This must never be called more than once.
    package mutating func receivedRemoteSettings(
        maxQueueSize: Int,
        dynamicTableSize: Int
    ) -> GotRemoteSettingsAction? {
        self.encoderState.receivedRemoteSettings(maxQueueSize: maxQueueSize, dynamicTableSize: dynamicTableSize)
    }

    package enum OutboundEncoderStreamReadyAction: Hashable, Sendable {
        case sendEncoderInstruction(QPACKEncoderInstruction?)
    }

    /// Call this when the outbound encoder stream is ready. It is an error to call this when not asked for (via ``GotRemoteSettingsAction``).
    /// It is also an error to call this twice.
    package mutating func outboundEncoderStreamReady() -> OutboundEncoderStreamReadyAction {
        switch self.encoderState.outboundEncoderStreamReady() {
        case .sendEncoderInstruction(let instruction):
            return .sendEncoderInstruction(instruction)
        }
    }

    package enum OutboundDecoderStreamReadyAction: Hashable, Sendable {
        case sendDecoderInstructions(Deque<QPACKDecoderInstruction>)
    }

    package mutating func outboundDecoderStreamReady() -> OutboundDecoderStreamReadyAction? {
        switch self.outboundDecoderInstructionQueue.outboundDecoderStreamReady() {
        case .sendDecoderInstructions(let instructions):
            return .sendDecoderInstructions(instructions)
        case .none:
            return .none
        }
    }

    package mutating func encodeHeaders(_ headers: [HTTPField], forStream streamID: QUICStreamID) -> QPACKEncodeResult {
        self.encoderState.encodeHeaders(headers, forStream: streamID)
    }

    package enum DecodeHeaderAction {
        /// Send this qpack decode result to the relevant stream.
        case informDecodeResult(InformDecodeResult)

        /// Send this qpack decoder error to the relevant stream. This is a stream-level error.
        case informDecodeError(InformDecodeError)

        /// Send a connection-level error.
        case emitConnectionError(HTTP3Error)

        package struct InformDecodeResult: Hashable, Sendable {
            package var fields: [HTTPField]
            package var headers: HTTP3PartialFrame.Headers
            package var streamID: QUICStreamID
            package var instructionToWrite: QPACKDecoderInstruction?

            package init(
                fields: [HTTPField],
                headers: HTTP3PartialFrame.Headers,
                streamID: QUICStreamID,
                instructionToWrite: QPACKDecoderInstruction?
            ) {
                self.fields = fields
                self.headers = headers
                self.streamID = streamID
                self.instructionToWrite = instructionToWrite
            }
        }

        package struct InformDecodeError {
            package var error: HTTP3Error
            package var headers: HTTP3PartialFrame.Headers
            package var streamID: QUICStreamID

            package init(error: HTTP3Error, headers: HTTP3PartialFrame.Headers, streamID: QUICStreamID) {
                self.error = error
                self.headers = headers
                self.streamID = streamID
            }
        }
    }

    package mutating func decodeHeaders(
        _ headers: HTTP3PartialFrame.Headers,
        forStream streamID: QUICStreamID
    ) -> DecodeHeaderAction? {
        @inline(never)
        func invalidFieldSectionPrefixError(location: HTTP3Error.SourceLocation) -> HTTP3Error {
            HTTP3Error(
                code: .qpackDecoderError,
                message: "Invalid field section prefix",
                cause: nil,
                errorCode: .QPACK_DECOMPRESSION_FAILED,
                location: location
            )
        }
        guard let prefix = self.qpackDecoder.decodeFieldSectionPrefix(headers.fieldSection.prefix) else {
            // The field section prefix can't have been produced by a conformant encoder
            // RFC 9204 4.5.1.1: If the decoder encounters a value of EncodedInsertCount that could not have been produced by a
            // conformant encoder, it MUST treat this as a connection error of type QPACK_DECOMPRESSION_FAILED.
            return .emitConnectionError(invalidFieldSectionPrefixError(location: .here()))
        }
        let result = self.qpackDecoder.decodeFieldSection(
            prefix: prefix,
            lines: headers.fieldSection.lines,
            streamID: streamID
        )
        switch result {
        case .success(let fields, let instruction):
            let writeAction = instruction.flatMap { self.outboundDecoderInstructionQueue.writeDecoderInstruction($0) }
            switch writeAction {
            case .sendDecoderInstruction(let instruction):
                return .informDecodeResult(
                    .init(fields: fields, headers: headers, streamID: streamID, instructionToWrite: instruction)
                )
            case .none:
                return .informDecodeResult(
                    .init(fields: fields, headers: headers, streamID: streamID, instructionToWrite: nil)
                )
            }

        case .missingInsertCount:
            do {
                try self.decoderQueue.add(
                    .init(headers: headers, prefix: prefix, lines: headers.fieldSection.lines, streamID: streamID)
                )
                return nil
            } catch {
                switch error {
                case .reachedMaxSize:
                    @inline(never)
                    func tooManyBlockedStreamsError(
                        cause: any Error,
                        location: HTTP3Error.SourceLocation
                    ) -> HTTP3Error {
                        HTTP3Error(
                            code: .qpackDecoderError,
                            message: "Too many streams blocked on QPACK",
                            cause: cause,
                            errorCode: .QPACK_DECOMPRESSION_FAILED,
                            location: location
                        )
                    }
                    return .emitConnectionError(tooManyBlockedStreamsError(cause: error, location: .here()))
                }
            }

        case .error(let qpackError):
            switch self.errorTypeForDecoderError(qpackError, streamID: streamID) {
            case .connection(let h3Error):
                return .emitConnectionError(h3Error)
            case .stream(let h3Error):
                return .informDecodeError(.init(error: h3Error, headers: headers, streamID: streamID))
            }
        }
    }

    /// Check if any previously-queued decode is now decodable.
    /// This function should be called repeatedly after new input (eg. new incoming instructions) until it returns nil
    package mutating func checkPendingDecodes() -> DecodeHeaderAction? {
        guard let entry = self.decoderQueue.popIfDecodable(availableInsertCount: self.qpackDecoder.insertCount) else {
            return nil
        }
        let qpackResult = self.qpackDecoder.decodeFieldSection(
            prefix: entry.prefix,
            lines: entry.lines,
            streamID: entry.streamID
        )
        switch qpackResult {
        case .missingInsertCount:
            // This implies a bug in `popIfDecodable` because we shouldn't get here if something isn't decodable yet
            fatalError("Tried to decode an entry which can't be decoded")
        case .error(let qpackError):
            switch self.errorTypeForDecoderError(qpackError, streamID: entry.streamID) {
            case .connection(let h3Error):
                return .emitConnectionError(h3Error)
            case .stream(let h3Error):
                return .informDecodeError(.init(error: h3Error, headers: entry.headers, streamID: entry.streamID))
            }
        case .success(let fields, let instruction):
            let writeAction = instruction.flatMap { self.outboundDecoderInstructionQueue.writeDecoderInstruction($0) }
            switch writeAction {
            case .sendDecoderInstruction(let instruction):
                return .informDecodeResult(
                    .init(
                        fields: fields,
                        headers: entry.headers,
                        streamID: entry.streamID,
                        instructionToWrite: instruction
                    )
                )
            case .none:
                return .informDecodeResult(
                    .init(
                        fields: fields,
                        headers: entry.headers,
                        streamID: entry.streamID,
                        instructionToWrite: nil
                    )
                )
            }
        }
    }

    private enum ErrorType {
        case connection(HTTP3Error)
        case stream(HTTP3Error)
    }

    private func errorTypeForDecoderError(
        _ qpackError: QPACKDecoderError,
        streamID: QUICStreamID
    ) -> ErrorType {
        switch qpackError {
        case .invalidFieldSection, .invalidReference:
            // If the decoder encounters a reference in a field line representation to a dynamic table entry that has
            // already been evicted or that has an absolute index greater than or equal to the declared Required
            // Insert Count (Section 4.5.1), it MUST treat this as a connection error of type QPACK_DECOMPRESSION_FAILED.
            let h3Error = HTTP3Error(
                code: .qpackDecoderError,
                message: "Could not decode QPACK headers for stream \(streamID)",
                cause: qpackError,
                errorCode: .QPACK_DECOMPRESSION_FAILED,
                location: .here()
            )
            return .connection(h3Error)
        case .invalidHeaderName:
            // Here we did decode fine, but the header is not valid in HTTP/3 (e.g. it isn't lower case)
            // This is a malformed message, a stream level error. Not a connection error
            let h3Error = HTTP3Error(
                code: .qpackDecoderError,
                message: "Could not decode QPACK headers",
                cause: qpackError,
                errorCode: .H3_MESSAGE_ERROR,
                location: .here()
            )
            return .stream(h3Error)
        }
    }

    package enum IncomingEncoderInstructionAction {
        /// The new incoming instruction resulted in previously-blocked headers now being decodable.
        case sendDecoderInstruction(QPACKDecoderInstruction)
        case emitConnectionError(HTTP3Error)
    }

    /// Inform the state machine of a new incoming instruction. After this, you should call ``checkPendingDecodes()`` because the new instruction
    /// may have unblocked a pending decode.
    package mutating func receivedIncomingEncoderInstruction(
        _ instruction: QPACKEncoderInstruction
    ) -> IncomingEncoderInstructionAction? {
        @inline(never)
        func invalidEncoderInstructionError(
            cause: any Error,
            location: HTTP3Error.SourceLocation
        ) -> HTTP3Error {
            HTTP3Error(
                code: .qpackEncoderStreamError,
                message: "Invalid encoder instruction",
                cause: cause,
                errorCode: .QPACK_ENCODER_STREAM_ERROR,
                location: location
            )
        }
        do {
            let i = try self.qpackDecoder.processInstruction(instruction)
            switch self.outboundDecoderInstructionQueue.writeDecoderInstruction(i) {
            case .sendDecoderInstruction(let instruction):
                return .sendDecoderInstruction(instruction)
            case .none:
                return .none
            }
        } catch {
            return .emitConnectionError(invalidEncoderInstructionError(cause: error, location: .here()))
        }
    }

    package enum IncomingDecoderInstructionAction {
        case emitConnectionError(HTTP3Error)
    }

    package mutating func receivedIncomingDecoderInstruction(
        _ instruction: QPACKDecoderInstruction
    ) -> IncomingDecoderInstructionAction? {
        switch self.encoderState.receivedIncomingDecoderInstruction(instruction) {
        case .emitConnectionError(let e):
            return .emitConnectionError(e)
        case .none:
            return .none
        }
    }

    package enum RequestStreamClosedAction: Hashable, Sendable {
        case sendDecoderInstruction(QPACKDecoderInstruction)
    }

    /// Call this when a request stream has been closed, regardless of how / why it was closed.
    /// It will clean up related state.
    /// - Parameters:
    ///   - streamID: The ID of the stream which was closed.
    ///   - seenEOF: True if we closed cleanly. That means no unprocessed encoded field sections, and we didn't stop reading an unfinished stream.
    ///     This is important because if there is a chance of unprocessed field section then we need to inform the peer so that their qpack encoder
    ///     knows not to expect acks from any field sections it may have sent on this stream.
    ///     See RFC 9204 § 2.2.2.2 for more info.
    /// - Returns: Actions to take next.
    package mutating func requestStreamClosed(streamID: QUICStreamID, seenEOF: Bool) -> RequestStreamClosedAction? {
        if seenEOF {
            // We currently don't need to do anything for cleanly-closed streams
            return nil
        }

        // If we saw EOF, there couldn't have been anything in the decoder queue.
        // Since we didn't see EOF, there might be, and we should drop them because the stream is gone.
        self.decoderQueue.removeAll(forStream: streamID)

        // Since we didn't see EOF, we need to tell the remote encoder that it should not expect acks for any
        // encoded field sections it sent on this stream.
        // Whereas if we has seen EOF then we already processed everything.
        let instruction = self.qpackDecoder.cancelStream(streamID: streamID)
        guard let instruction else {
            return nil
        }
        switch self.outboundDecoderInstructionQueue.writeDecoderInstruction(instruction) {
        case .sendDecoderInstruction(let instruction):
            return .sendDecoderInstruction(instruction)
        case .none:
            return nil
        }
    }
}
