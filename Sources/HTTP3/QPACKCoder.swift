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

public import HTTPTypes
public import NIOQUICHelpers
@_spi(PackageInternal) public import QPACK

/// A stream to send encoder instructions on, which the peer can then use in its QPACKDecoder
///
/// This is the unidirectional QPACK encoder stream described in RFC 9204 § 4.2.1. There is at most one of these
/// per connection and it is only created if the peer's settings permit the use of the dynamic table. Create it in
/// response to ``ConnectionDelegate/makeOutboundEncoderStream()`` and hand it to
/// ``QPACKCoder/outboundEncoderStreamReady(_:)``.
@_spi(PackageInternal)
public protocol QPACKOutboundEncoderStream: ~Copyable {
    /// Send encoder instructions to the peer's decoder.
    ///
    /// The instructions must be written in the order given, and must not be reordered with respect to instructions
    /// from any earlier call.
    ///
    /// - Parameter instructions: The instructions to write to the encoder stream.
    func sendInstructions(_ instructions: some Collection<QPACKEncoderInstruction>)
}

/// A stream to send decoder acknowledgements, stream cancellations and insert count increments on.
///
/// This is the unidirectional QPACK decoder stream described in RFC 9204 § 4.2.2. There is at most one of these per
/// connection and, unlike the encoder stream, it is always created. Hand it to
/// ``QPACKCoder/outboundDecoderStreamReady(_:)`` once it exists; the coder buffers any instructions produced before
/// then and flushes them at that point.
@_spi(PackageInternal)
public protocol QPACKOutboundDecoderStream: ~Copyable {
    /// Send a single decoder instruction to the peer's encoder.
    ///
    /// - Parameter instruction: The instruction to write to the decoder stream.
    func sendInstruction(_ instruction: QPACKDecoderInstruction)

    /// Send decoder instructions to the peer's encoder.
    ///
    /// The instructions must be written in the order given, and must not be reordered with respect to instructions
    /// from any earlier call.
    ///
    /// - Parameter instruction: The instructions to write to the decoder stream.
    func sendInstructions(_ instruction: some Collection<QPACKDecoderInstruction>)
}

/// An object representing an HTTP3Connection to forward connection level errors to.
@_spi(PackageInternal)
public protocol ConnectionDelegate {
    /// A connection level error has occurred and the connection must be torn down.
    ///
    /// The error's ``HTTP3Error/h3ErrorCode`` is the code to close the QUIC connection with.
    ///
    /// - Parameter error: The error which requires the connection to be closed.
    func connectionError(_ error: HTTP3Error)

    /// The coder wants to use the QPACK dynamic table and therefore needs an outbound encoder stream.
    ///
    /// Open a unidirectional stream of type ``HTTP3StreamType/Unidirectional/qpackEncoder`` and pass it back to
    /// ``QPACKCoder/outboundEncoderStreamReady(_:)``. This is called at most once per connection.
    ///
    /// - Important: Until the stream has been handed back, the coder can only encode using the static table.
    func makeOutboundEncoderStream()
}

/// An object that is interested in the async QPACK decode result. In most cases this will be an object representing
/// a HTTP3 stream.
@_spi(PackageInternal)
public protocol QPACKDecodeReceiver {
    /// Inform the QPACKDecodeReceiver that a decode has happened.
    ///
    /// This is called exactly once per ``QPACKCoder/decodeHeaders(_:streamID:decodeReceiver:)`` call, unless the
    /// stream is closed via ``QPACKCoder/requestStreamClosed(streamID:seenEOF:)`` while the decode is still
    /// blocked, in which case the pending decode is dropped and this is never called.
    ///
    /// A failure is not necessarily limited to this stream: some QPACK failures are fatal to the connection, and
    /// in that case the ``ConnectionDelegate`` is told about the same error.
    ///
    /// - Important: If the decoder has all the necessary QPACK decode information available the decoder
    ///              will invoke this method syncronously from
    ///              ``QPACKCoder/decodeHeaders(_:streamID:decodeReceiver:)``.
    ///
    /// - Parameter result: The decoded fields, or the error which prevented decoding.
    func decodeResult(_ result: Result<[HTTPField], any Error>)
}

/// An object encapsulating all the QPACK encoding and decoding. It implements the QPACK procedures while being
/// abstract about the implementations that drive the QPACK coding.
///
/// ## Overview
///
/// A ``QPACKCoder`` owns both halves of QPACK for one connection: the encoder, which compresses outgoing header
/// field sections and emits encoder instructions for the peer's decoder, and the decoder, which decompresses
/// incoming field sections and emits decoder instructions for the peer's encoder. It is a pure state machine
/// driver: it never performs I/O itself, but instead calls out to the four types it is generic over.
///
/// ## Lifecycle
///
/// 1. Create the coder with the limits this endpoint will advertise in its own SETTINGS frame.
/// 2. Once the outbound QPACK decoder stream exists, call ``outboundDecoderStreamReady(_:)``. Decoder instructions
///    produced before this point are buffered and flushed then.
/// 3. When the peer's SETTINGS arrive, call ``receivedRemoteSettings(maxQueueSize:effectiveDynamicTableSize:)``. If
///    the peer permits the dynamic table, the coder asks for an encoder stream via
///    ``ConnectionDelegate/makeOutboundEncoderStream()``; supply it with ``outboundEncoderStreamReady(_:)``. Until
///    then — and forever, if the peer advertised a zero sized table — encoding uses the static table only.
/// 4. Feed the peer's instruction streams in with ``receivedIncomingEncoderInstruction(_:)`` and
///    ``receivedIncomingDecoderInstruction(_:)``, encode with ``encodeHeaders(_:streamID:)``, decode with
///    ``decodeHeaders(_:streamID:decodeReceiver:)``, and report closed streams with
///    ``requestStreamClosed(streamID:seenEOF:)``.
///
/// ## Errors
///
/// QPACK failures come in two flavours. A malformed message fails only the stream it arrived on and is reported to
/// that stream's ``QPACKDecodeReceiver``. Anything which leaves the two dynamic tables out of sync is fatal to the
/// whole connection and is reported to the ``ConnectionDelegate``; the receiver is failed as well so that it does
/// not wait for a result which will never arrive.
///
/// - Important: This type is not thread safe. All calls must be made from the connection's own serial context.
@_spi(PackageInternal)
public final class QPACKCoder<
    OutboundEncoderStream: QPACKOutboundEncoderStream & ~Copyable,
    OutboundDecoderStream: QPACKOutboundDecoderStream & ~Copyable,
    ConnectionDelegate: HTTP3.ConnectionDelegate,
    DecodeReceiver: QPACKDecodeReceiver
> {

    /// The outbound QPACK encoder stream, `nil` until ``outboundEncoderStreamReady(_:)`` supplies it.
    ///
    /// Force unwrapping this is safe wherever the state machine has handed us an encoder instruction to write: the
    /// encoder state machine only leaves its static-only states in `EncoderStateMachine.outboundEncoderStreamReady()`,
    /// which is reached only from ``outboundEncoderStreamReady(_:)`` below, after this property has been set. Once
    /// set it is never cleared.
    private var outboundEncoderStream: OutboundEncoderStream?

    /// The outbound QPACK decoder stream, `nil` until ``outboundDecoderStreamReady(_:)`` supplies it.
    ///
    /// Force unwrapping this is safe wherever the state machine has handed us a decoder instruction to write: every
    /// such instruction comes out of `OutboundDecoderInstructionQueue.writeDecoderInstruction(_:)`, which buffers
    /// rather than returning an instruction until it has been moved to its `noQueue` state. That move happens only
    /// in `OutboundDecoderInstructionQueue.outboundDecoderStreamReady()`, reached only from
    /// ``outboundDecoderStreamReady(_:)`` below, after this property has been set. Once set it is never cleared.
    private var outboundDecoderStream: OutboundDecoderStream?

    private var stateMachine: QPACKStateMachine<DecodeReceiver>

    private let connection: ConnectionDelegate

    /// Create a new ``QPACKCoder``.
    ///
    /// The two limits describe what this endpoint's *decoder* is willing to accept from the peer's encoder, and
    /// must match the `SETTINGS_QPACK_MAX_TABLE_CAPACITY` and `SETTINGS_QPACK_BLOCKED_STREAMS` values this
    /// endpoint advertises in its own SETTINGS frame.
    ///
    /// - Parameters:
    ///   - decoderMaxTableSize: The maximum size, in bytes, of this endpoint's dynamic table. Pass `0` to refuse
    ///     the dynamic table entirely.
    ///   - decoderMaxBlockedStreams: How many streams may be simultaneously blocked waiting for entries which
    ///     haven't arrived on the peer's encoder stream yet. Exceeding this is a connection error.
    ///   - errorDelegate: The connection to report connection level errors to, and to ask for an outbound encoder
    ///     stream when one is needed.
    @_spi(PackageInternal)
    public init(
        decoderMaxTableSize: Int,
        decoderMaxBlockedStreams: Int,
        errorDelegate: ConnectionDelegate
    ) {
        self.stateMachine = QPACKStateMachine(
            decoderMaxTableSize: decoderMaxTableSize,
            decoderMaxBlockedStreams: decoderMaxBlockedStreams
        )
        self.connection = errorDelegate
    }

    /// Call this method when your HTTP3 connection has received new settings on the
    /// settings stream. When receiving settings for the first time, the QPACKCoder will
    /// call its ``ConnectionDelegate``, to open the outbound encoder stream.
    ///
    /// If the peer advertised a zero sized dynamic table then no encoder stream is requested, since it would never
    /// be used. See RFC 9204 § 4.2.
    ///
    /// - Precondition: The peer may only send SETTINGS once, so this must not be called more than once.
    ///
    /// - Parameters:
    ///   - maxQueueSize: The peer's `SETTINGS_QPACK_BLOCKED_STREAMS`: how many streams this endpoint's encoder may
    ///     leave blocked on the peer's decoder at a time.
    ///   - effectiveDynamicTableSize: The peer's `SETTINGS_QPACK_MAX_TABLE_CAPACITY`: the largest dynamic table
    ///     this endpoint's encoder may ask the peer's decoder to keep.
    @_spi(PackageInternal)
    public func receivedRemoteSettings(
        maxQueueSize: Int,
        effectiveDynamicTableSize: Int
    ) {
        let action = self.stateMachine.receivedRemoteSettings(
            maxQueueSize: maxQueueSize,
            effectiveDynamicTableSize: effectiveDynamicTableSize
        )

        switch action {
        case .makeEncoderInstructionStream:
            self.connection.makeOutboundEncoderStream()
        case .none:
            break
        }
    }

    // MARK: Encode

    /// QPACK encode your http fields. If new instructions need to be send to the peer as a side-effect of the encode the
    /// QPACKCoder will inform the ``QPACKOutboundEncoderStream`` via the ``QPACKOutboundEncoderStream/sendInstructions(_:)``
    /// method call.
    ///
    /// Use this method for both headers and trailers.
    ///
    /// - Important: The returned field section references the encoder's dynamic table as it stands at this moment.
    ///   It must be written to the stream in the same order as it was encoded, otherwise the peer's decoder will
    ///   see references it cannot resolve.
    ///
    /// - Parameters:
    ///   - fields: The header fields to encode.
    ///   - streamID: The stream the encoded fields will be sent on.
    /// - Returns: The encoded field section, ready to be framed as a HEADERS frame.
    @_spi(PackageInternal)
    public func encodeHeaders(_ fields: [HTTPField], streamID: QUICStreamID) -> HTTP3PartialFrame.Headers {
        let result = self.stateMachine.encodeHeaders(fields, forStream: streamID)

        if !result.instructions.isEmpty {
            // Safe to unwrap: the encoder state machine only produces instructions once it is using the dynamic
            // table, which it only starts doing from `outboundEncoderStreamReady(_:)`, after the stream is set.
            self.outboundEncoderStream!.sendInstructions(result.instructions)
        }

        return HTTP3PartialFrame.Headers(fieldSection: result.fieldSection)
    }

    /// Call this method as a response to the ``ConnectionDelegate/makeOutboundEncoderStream()``
    /// invocation with a stream that conforms to the ``QPACKOutboundEncoderStream``
    /// protocol.
    ///
    /// The coder immediately writes a `Set Dynamic Table Capacity` instruction on the new stream, after which it
    /// starts using the dynamic table for encoding.
    ///
    /// - Precondition: Only call this after ``ConnectionDelegate/makeOutboundEncoderStream()`` has asked for the
    ///   stream, and only once.
    ///
    /// - Parameter stream: The newly created outbound QPACK encoder stream.
    @_spi(PackageInternal)
    public func outboundEncoderStreamReady(_ stream: consuming OutboundEncoderStream) {
        self.outboundEncoderStream = consume stream

        let action = self.stateMachine.outboundEncoderStreamReady()
        switch action {
        case .sendEncoderInstruction(let instruction):
            guard let instruction else { break }
            self.outboundEncoderStream!.sendInstructions(CollectionOfOne(instruction))
        }
    }

    /// Call this method when an instruction has been received on the peer's QPACK decoder stream.
    ///
    /// These instructions — section acknowledgements, stream cancellations and insert count increments — tell this
    /// endpoint's encoder which of its dynamic table entries the peer has definitely seen, which lets the encoder
    /// evict them. Receiving one when the dynamic table isn't in use, or one which doesn't match the encoder's
    /// state, is a connection error of type `QPACK_DECODER_STREAM_ERROR` and is reported to the
    /// ``ConnectionDelegate``.
    ///
    /// - Parameter instruction: The instruction received on the peer's decoder stream.
    @_spi(PackageInternal)
    public func receivedIncomingDecoderInstruction(_ instruction: QPACKDecoderInstruction) {
        switch self.stateMachine.receivedIncomingDecoderInstruction(instruction) {
        case .emitConnectionError(let error):
            self.connection.connectionError(error)
        case .none:
            break
        }
    }

    // MARK: Decode

    /// Decode incoming http fields. Use this method for headers and trailers.
    ///
    /// This method does not return the decoded http fields syncronously, as decoding might depend
    /// on decoder instructions that arrive asyncronously via ``receivedIncomingDecoderInstruction(_:)``
    ///
    /// If the field section references dynamic table entries which haven't arrived yet, the stream becomes blocked
    /// and the decode completes later, from ``receivedIncomingEncoderInstruction(_:)``. Blocking more streams than
    /// the `decoderMaxBlockedStreams` promised at init is a connection error.
    ///
    /// - Important: If the decoder has all the necessary QPACK decode information available the decoder
    ///              will invoke the ``QPACKDecodeReceiver/decodeResult(_:)`` method syncronously.
    ///
    /// - Parameters:
    ///   - headers: The headers to QPACK decode
    ///   - streamID: The stream id of the stream, that received the header frame
    ///   - decodeReceiver: The object that needs to be informed about the decode result.
    @_spi(PackageInternal)
    public func decodeHeaders(
        _ headers: HTTP3PartialFrame.Headers,
        streamID: QUICStreamID,
        decodeReceiver: DecodeReceiver
    ) {
        let action = self.stateMachine.decodeHeaders(headers, forStream: streamID, context: decodeReceiver)
        self.runDecodeHeaderAction(action)
    }

    /// Call this method as soon as the outbound decoder stream has been created after connection
    /// creation.
    ///
    /// Decoder instructions produced before this point are buffered, and are all written to the stream here.
    ///
    /// - Precondition: Call this at most once.
    ///
    /// - Parameter stream: The newly created outbound QPACK decoder stream.
    @_spi(PackageInternal)
    public func outboundDecoderStreamReady(_ stream: consuming OutboundDecoderStream) {
        self.outboundDecoderStream = consume stream

        let action = self.stateMachine.outboundDecoderStreamReady()
        switch action {
        case .sendDecoderInstructions(let instructions):
            self.outboundDecoderStream!.sendInstructions(instructions)
        case .none:
            break
        }
    }

    /// Call this method when an instruction has been received on the peer's QPACK encoder stream.
    ///
    /// These instructions maintain this endpoint's dynamic table. Applying one may unblock any number of field
    /// sections which were waiting for it, and each of their ``QPACKDecodeReceiver``s is called synchronously from
    /// this method, in ascending order of required insert count. An instruction which the decoder cannot apply is
    /// a connection error of type `QPACK_ENCODER_STREAM_ERROR` and is reported to the ``ConnectionDelegate``.
    ///
    /// - Parameter instruction: The instruction received on the peer's encoder stream.
    @_spi(PackageInternal)
    public func receivedIncomingEncoderInstruction(
        _ instruction: QPACKEncoderInstruction
    ) {
        let action = self.stateMachine.receivedIncomingEncoderInstruction(instruction)
        switch action {
        case .sendDecoderInstruction(let qPACKDecoderInstruction):
            // Safe to unwrap: see `outboundDecoderStream`.
            self.outboundDecoderStream!.sendInstruction(qPACKDecoderInstruction)
        case .emitConnectionError(let http3Error):
            self.connection.connectionError(http3Error)
        case .none:
            break
        }

        // A single instruction can unblock more than one stream, so we must drain the queue. This terminates
        // because every non-nil result pops an entry off the pending decode queue.
        while let decodeAction = self.stateMachine.checkPendingDecodes() {
            self.runDecodeHeaderAction(decodeAction)
        }
    }

    private func runDecodeHeaderAction(_ action: QPACKStateMachine<DecodeReceiver>.DecodeHeaderAction?) {
        switch action {
        case .informDecodeResult(let result, let receiver):
            if let instruction = result.instructionToWrite {
                // Safe to unwrap: see `outboundDecoderStream`.
                self.outboundDecoderStream!.sendInstruction(instruction)
            }
            receiver.decodeResult(.success(result.fields))

        case .informDecodeError(let informDecodeError, let receiver):
            receiver.decodeResult(.failure(informDecodeError.error))

        case .emitConnectionError(let http3Error, let receiver):
            self.connection.connectionError(http3Error)
            receiver.decodeResult(.failure(http3Error))

        case .none:
            // the required encoder dynamic table update hasn't arrived yet.
            break
        }
    }

    // MARK: Stream management

    /// Call this method when a stream has been closed. If the decoder was waiting for a peer's encoder
    /// instructions to decode the closed stream, the coder must inform the peer's encoder that this stream
    /// has been cancelled.
    ///
    /// Call this however the stream ended: cleanly, reset, or because the connection is going away.
    ///
    /// - Parameters:
    ///   - streamID: The ID of the stream which was closed.
    ///   - seenEOF: `true` if the stream closed cleanly, meaning every field section on it was processed. If
    ///     `false`, there may be field sections this endpoint will never acknowledge, so the peer's encoder is
    ///     told to stop expecting acknowledgements for the stream. See RFC 9204 § 2.2.2.2.
    @_spi(PackageInternal)
    public func requestStreamClosed(streamID: QUICStreamID, seenEOF: Bool) {
        switch self.stateMachine.requestStreamClosed(streamID: streamID, seenEOF: seenEOF) {
        case .sendDecoderInstruction(let instruction):
            // Safe to unwrap: see `outboundDecoderStream`.
            self.outboundDecoderStream!.sendInstruction(instruction)
        case .none:
            break
        }
    }
}
