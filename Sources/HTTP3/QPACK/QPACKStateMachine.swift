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
import HTTPTypes
import NIOQUICHelpers
@_spi(PackageInternal) import QPACK

/// A state machine which holds qpack encoder and decoder.
/// You can ask it to encode/decode things, and inform it of incoming instructions.
/// It will then return actions to be taken.
struct QPACKStateMachine<DecodeContext>: ~Copyable {
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

        private init(state: consuming State) {
            self.state = state
        }

        init() {
            self.init(state: .initial(.init(encoder: .init())))
        }

        mutating func receivedRemoteSettings(
            maxQueueSize: Int,
            effectiveDynamicTableSize: Int
        ) -> GotRemoteSettingsAction? {
            switch consume self.state {
            case .initial(let initial):
                // RFC 9204 § 4.2: An endpoint MAY avoid creating an encoder stream if it will not be used
                if effectiveDynamicTableSize == 0 {
                    self = .init(
                        state: .withoutDynamic(
                            .init(encoder: initial.encoder)
                        )
                    )
                    return nil
                } else {
                    self = .init(
                        state: .awaitingStream(
                            .init(
                                encoder: initial.encoder,
                                maxQueueSize: maxQueueSize,
                                dynamicTableSize: effectiveDynamicTableSize
                            )
                        )
                    )
                    return .makeEncoderInstructionStream
                }
            case .awaitingStream(let awaitingStream):
                self = .init(state: .awaitingStream(awaitingStream))
                return .emitConnectionError(.duplicateSettings)
            case .withDynamic(let withDynamic):
                self = .init(state: .withDynamic(withDynamic))
                return .emitConnectionError(.duplicateSettings)
            case .withoutDynamic(let withoutDynamic):
                self = .init(state: .withoutDynamic(withoutDynamic))
                return .emitConnectionError(.duplicateSettings)
            }
        }

        enum OutboundEncoderStreamReadyAction {
            case sendEncoderInstruction(QPACKEncoderInstruction?)
        }

        mutating func outboundEncoderStreamReady() -> OutboundEncoderStreamReadyAction {
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
                    )
                )
                return .sendEncoderInstruction(instruction)
            }
        }

        mutating func encodeHeaders(_ headers: [HTTPField], forStream streamID: QUICStreamID) -> QPACKEncodeResult {
            switch consume self.state {
            case .initial(let initial):
                let result = QPACKEncodeResult(fieldSection: initial.encoder.encode(headers: headers), instructions: [])
                self = .init(state: .initial(initial))
                return result
            case .awaitingStream(let awaiting):
                let result = QPACKEncodeResult(
                    fieldSection: awaiting.encoder.encode(headers: headers),
                    instructions: []
                )
                self = .init(state: .awaitingStream(awaiting))
                return result
            case .withoutDynamic(let woDynamic):
                let result = QPACKEncodeResult(
                    fieldSection: woDynamic.encoder.encode(headers: headers),
                    instructions: []
                )
                self = .init(state: .withoutDynamic(woDynamic))
                return result
            case .withDynamic(var withDynamic):
                let result = withDynamic.encoder.encode(headers: headers, forStream: streamID)
                self = .init(state: .withDynamic(withDynamic))
                return result
            }
        }

        enum IncomingDecoderInstructionAction {
            case emitConnectionError(QPACKError)
        }

        fileprivate mutating func receivedIncomingDecoderInstruction(
            _ instruction: QPACKDecoderInstruction
        ) -> IncomingDecoderInstructionAction? {
            switch consume self.state {
            case .initial(let initial):
                self = .init(state: .initial(initial))
                return .emitConnectionError(.decoderInstructionWithoutDynamicTable)
            case .awaitingStream(let awaitingStream):
                self = .init(state: .awaitingStream(awaitingStream))
                return .emitConnectionError(.decoderInstructionWithoutDynamicTable)
            case .withoutDynamic(let withoutDynamic):
                self = .init(state: .withoutDynamic(withoutDynamic))
                return .emitConnectionError(.decoderInstructionWithoutDynamicTable)
            case .withDynamic(var withDynamic):
                do {
                    try withDynamic.encoder.processInstruction(instruction)
                    self = .init(state: .withDynamic(withDynamic))
                    return nil
                } catch {
                    // TODO: move to error state?
                    self = .init(state: .withDynamic(withDynamic))
                    return .emitConnectionError(.invalidDecoderInstruction)
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
    private var decoderQueue: FieldSectionQueue<DecodeContext>
    private var outboundDecoderInstructionQueue: OutboundDecoderInstructionQueue

    init(decoderMaxTableSize: Int, decoderMaxBlockedStreams: Int) {
        self.encoderState = .init()
        self.qpackDecoder = .init(dynamicTableMaxCapacity: decoderMaxTableSize)
        self.decoderQueue = .init(maxItems: decoderMaxBlockedStreams)
        self.outboundDecoderInstructionQueue = .init()
    }

    enum GotRemoteSettingsAction {
        case makeEncoderInstructionStream
        case emitConnectionError(QPACKError)
    }

    /// Call this when the settings have been received from the remote.
    ///
    /// The peer may only send SETTINGS once: a second call returns ``GotRemoteSettingsAction/emitConnectionError(_:)``
    /// and leaves the encoder state untouched.
    mutating func receivedRemoteSettings(
        maxQueueSize: Int,
        effectiveDynamicTableSize: Int
    ) -> GotRemoteSettingsAction? {
        self.encoderState.receivedRemoteSettings(
            maxQueueSize: maxQueueSize,
            effectiveDynamicTableSize: effectiveDynamicTableSize
        )
    }

    enum OutboundEncoderStreamReadyAction: Hashable, Sendable {
        case sendEncoderInstruction(QPACKEncoderInstruction?)
    }

    /// Call this when the outbound encoder stream is ready. It is an error to call this when not asked for (via ``GotRemoteSettingsAction``).
    /// It is also an error to call this twice.
    mutating func outboundEncoderStreamReady() -> OutboundEncoderStreamReadyAction {
        switch self.encoderState.outboundEncoderStreamReady() {
        case .sendEncoderInstruction(let instruction):
            return .sendEncoderInstruction(instruction)
        }
    }

    enum OutboundDecoderStreamReadyAction: Hashable, Sendable {
        case sendDecoderInstructions(Deque<QPACKDecoderInstruction>)
    }

    mutating func outboundDecoderStreamReady() -> OutboundDecoderStreamReadyAction? {
        switch self.outboundDecoderInstructionQueue.outboundDecoderStreamReady() {
        case .sendDecoderInstructions(let instructions):
            return .sendDecoderInstructions(instructions)
        case .none:
            return .none
        }
    }

    mutating func encodeHeaders(_ headers: [HTTPField], forStream streamID: QUICStreamID) -> QPACKEncodeResult {
        self.encoderState.encodeHeaders(headers, forStream: streamID)
    }

    enum DecodeHeaderAction {
        /// Send this qpack decode result to the relevant stream.
        case informDecodeResult(InformDecodeResult, DecodeContext)

        /// Send this qpack decoder error to the relevant stream. This is a stream-level error.
        case informDecodeError(InformDecodeError, DecodeContext)

        /// Send a connection-level error.
        case emitConnectionError(QPACKError, DecodeContext)

        struct InformDecodeResult: Hashable, Sendable {
            var fields: [HTTPField]
            var streamID: QUICStreamID
            var instructionToWrite: QPACKDecoderInstruction?

            init(
                fields: [HTTPField],
                streamID: QUICStreamID,
                instructionToWrite: QPACKDecoderInstruction?
            ) {
                self.fields = fields
                self.streamID = streamID
                self.instructionToWrite = instructionToWrite
            }
        }

        struct InformDecodeError {
            var error: QPACKError
            var streamID: QUICStreamID

            init(error: QPACKError, streamID: QUICStreamID) {
                self.error = error
                self.streamID = streamID
            }
        }
    }

    mutating func decodeHeaders(
        _ fieldSection: FieldSection,
        forStream streamID: QUICStreamID,
        context: DecodeContext
    ) -> DecodeHeaderAction? {
        guard let prefix = self.qpackDecoder.decodeFieldSectionPrefix(fieldSection.prefix) else {
            // The field section prefix can't have been produced by a conformant encoder
            // RFC 9204 4.5.1.1: If the decoder encounters a value of EncodedInsertCount that could not have been produced by a
            // conformant encoder, it MUST treat this as a connection error of type QPACK_DECOMPRESSION_FAILED.
            return .emitConnectionError(.invalidFieldSectionPrefix, context)
        }
        let result = self.qpackDecoder.decodeFieldSection(
            prefix: prefix,
            lines: fieldSection.lines,
            streamID: streamID
        )
        switch result {
        case .success(let fields, let instruction):
            let writeAction = instruction.flatMap { self.outboundDecoderInstructionQueue.writeDecoderInstruction($0) }
            switch writeAction {
            case .sendDecoderInstruction(let instruction):
                return .informDecodeResult(
                    .init(fields: fields, streamID: streamID, instructionToWrite: instruction),
                    context
                )
            case .none:
                return .informDecodeResult(
                    .init(fields: fields, streamID: streamID, instructionToWrite: nil),
                    context
                )
            }

        case .missingInsertCount:
            do {
                try self.decoderQueue.add(
                    .init(
                        fieldSection: fieldSection,
                        prefix: prefix,
                        lines: fieldSection.lines,
                        streamID: streamID,
                        context: context
                    )
                )
                return nil
            } catch {
                switch error {
                case .reachedMaxSize:
                    return .emitConnectionError(.tooManyBlockedStreams, context)
                }
            }

        case .error(let decoderError):
            return self.decodeErrorAction(decoderError, streamID: streamID, context: context)
        }
    }

    /// Check if any previously-queued decode is now decodable.
    /// This function should be called repeatedly after new input (eg. new incoming instructions) until it returns nil
    mutating func checkPendingDecodes() -> DecodeHeaderAction? {
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
        case .error(let decoderError):
            return self.decodeErrorAction(decoderError, streamID: entry.streamID, context: entry.context)
        case .success(let fields, let instruction):
            let writeAction = instruction.flatMap { self.outboundDecoderInstructionQueue.writeDecoderInstruction($0) }
            switch writeAction {
            case .sendDecoderInstruction(let instruction):
                return .informDecodeResult(
                    .init(
                        fields: fields,
                        streamID: entry.streamID,
                        instructionToWrite: instruction
                    ),
                    entry.context
                )
            case .none:
                return .informDecodeResult(
                    .init(
                        fields: fields,
                        streamID: entry.streamID,
                        instructionToWrite: nil
                    ),
                    entry.context
                )
            }
        }
    }

    private func decodeErrorAction(
        _ decoderError: QPACKDecoderError,
        streamID: QUICStreamID,
        context: DecodeContext
    ) -> DecodeHeaderAction {
        let error = QPACKError.decodeError(decoderError)
        if error.isConnectionError {
            return .emitConnectionError(error, context)
        } else {
            return .informDecodeError(.init(error: error, streamID: streamID), context)
        }
    }

    enum IncomingEncoderInstructionAction {
        /// The new incoming instruction resulted in previously-blocked headers now being decodable.
        case sendDecoderInstruction(QPACKDecoderInstruction)
        case emitConnectionError(QPACKError)
    }

    /// Inform the state machine of a new incoming instruction. After this, you should call ``checkPendingDecodes()`` because the new instruction
    /// may have unblocked a pending decode.
    mutating func receivedIncomingEncoderInstruction(
        _ instruction: QPACKEncoderInstruction
    ) -> IncomingEncoderInstructionAction? {
        do {
            let i = try self.qpackDecoder.processInstruction(instruction)
            switch self.outboundDecoderInstructionQueue.writeDecoderInstruction(i) {
            case .sendDecoderInstruction(let instruction):
                return .sendDecoderInstruction(instruction)
            case .none:
                return .none
            }
        } catch {
            return .emitConnectionError(.invalidEncoderInstruction)
        }
    }

    enum IncomingDecoderInstructionAction {
        case emitConnectionError(QPACKError)
    }

    mutating func receivedIncomingDecoderInstruction(
        _ instruction: QPACKDecoderInstruction
    ) -> IncomingDecoderInstructionAction? {
        switch self.encoderState.receivedIncomingDecoderInstruction(instruction) {
        case .emitConnectionError(let e):
            return .emitConnectionError(e)
        case .none:
            return .none
        }
    }

    enum RequestStreamClosedAction: Hashable, Sendable {
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
    mutating func requestStreamClosed(streamID: QUICStreamID, seenEOF: Bool) -> RequestStreamClosedAction? {
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
