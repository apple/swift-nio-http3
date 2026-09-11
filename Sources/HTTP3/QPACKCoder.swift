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
/// This is the unidirectional QPACK encoder stream of RFC 9204 § 4.2.1. It only exists if the peer's settings
/// permit the dynamic table. Create it in response to ``ConnectionDelegate/makeOutboundEncoderStream()``.
@_spi(PackageInternal)
public protocol QPACKOutboundEncoderStream: ~Copyable {
    /// Write instructions to the stream, in the order given.
    mutating func sendInstructions(_ instructions: some Collection<QPACKEncoderInstruction>)
}

/// A stream to send decoder acknowledgements, stream cancellations and insert count increments on.
///
/// This is the unidirectional QPACK decoder stream of RFC 9204 § 4.2.2. Unlike the encoder stream it always
/// exists, but the coder buffers instructions until ``QPACKCoder/outboundDecoderStreamReady(_:)`` is called.
@_spi(PackageInternal)
public protocol QPACKOutboundDecoderStream: ~Copyable {
    /// Write an instruction to the stream.
    mutating func sendInstruction(_ instruction: QPACKDecoderInstruction)

    /// Write instructions to the stream, in the order given.
    mutating func sendInstructions(_ instruction: some Collection<QPACKDecoderInstruction>)
}

/// An object representing an HTTP3Connection to forward connection level errors to.
@_spi(PackageInternal)
public protocol QPACKConnectionDelegate {
    /// Tear the connection down. The error's ``HTTP3Error/h3ErrorCode`` is the code to close it with.
    func connectionError(_ error: HTTP3Error)

    /// Open a unidirectional ``HTTP3StreamType/Unidirectional/qpackEncoder`` stream and pass it to
    /// ``QPACKCoder/outboundEncoderStreamReady(_:)``.
    ///
    /// Called at most once per connection, and only if the peer permits the dynamic table. Until the stream is
    /// handed back the coder encodes with the static table only.
    func makeOutboundEncoderStream()
}

/// An object that is interested in the async QPACK decode result. In most cases this will be an object representing
/// a HTTP3 stream.
@_spi(PackageInternal)
public protocol QPACKDecodeReceiver {
    /// Inform the QPACKDecodeReceiver that a decode has happened.
    ///
    /// Called once per ``QPACKCoder/decodeHeaders(_:streamID:decodeReceiver:)``, unless the stream is closed via
    /// ``QPACKCoder/requestStreamClosed(streamID:seenEOF:)`` with `seenEOF: false` while the decode is still
    /// blocked, in which case the pending decode is dropped and this is never called.
    ///
    /// A failure isn't necessarily confined to this stream: some QPACK failures are fatal to the connection, and
    /// the ``ConnectionDelegate`` is given the same error.
    ///
    /// - Important: If the decoder has all the necessary QPACK decode information available the decoder
    ///              will invoke this method syncronously from
    ///              ``QPACKCoder/decodeHeaders(_:streamID:decodeReceiver:)``.
    func decodeResult(_ result: Result<[HTTPField], HTTP3Error>)
}

/// An object encapsulating all the QPACK encoding and decoding. It implements the QPACK procedures while being
/// abstract about the implementations that drive the QPACK coding. This object is intended to be shared across HTTP/3
/// streams.
///
/// The coder performs no I/O itself; it calls out to the four types it is generic over.
///
/// Setup is order dependent:
///
/// 1. Create the coder with the limits this endpoint advertises in its own SETTINGS frame.
/// 2. Call ``outboundDecoderStreamReady(_:)`` once that stream exists. Instructions produced before this are
///    buffered and flushed then.
/// 3. Call ``receivedRemoteSettings(maxQueueSize:effectiveDynamicTableSize:)`` when the peer's SETTINGS arrive. If
///    the peer permits the dynamic table the coder asks for an encoder stream via
///    ``ConnectionDelegate/makeOutboundEncoderStream()``; supply it with ``outboundEncoderStreamReady(_:)``. Until
///    then — and forever, if the peer advertised a zero sized table — encoding uses the static table only.
///
/// Failures come in two kinds: a malformed message fails only its own stream, via that stream's
/// ``QPACKDecodeReceiver``, while anything that leaves the two dynamic tables out of sync is fatal to the
/// connection and goes to the ``ConnectionDelegate`` as well as to the receiver.
///
/// - Note: This object retains its ``ConnectionDelegate``. If the object holding the QPACKCoder is also its
///   ``ConnectionDelegate`` (likely the HTTP3Connection), the two keep each other alive: the holder must drop
///   its reference to the coder to break the cycle.
@_spi(PackageInternal)
public final class QPACKCoder<
    OutboundEncoderStream: QPACKOutboundEncoderStream & ~Copyable,
    OutboundDecoderStream: QPACKOutboundDecoderStream & ~Copyable,
    ConnectionDelegate: HTTP3.QPACKConnectionDelegate,
    DecodeReceiver: QPACKDecodeReceiver
> {

    /// `nil` until ``outboundEncoderStreamReady(_:)`` supplies it, and never cleared afterwards.
    ///
    /// Force unwrapping is safe wherever the state machine hands us an encoder instruction: the encoder only
    /// leaves its static-only states in `EncoderStateMachine.outboundEncoderStreamReady()`, which is reached only
    /// from ``outboundEncoderStreamReady(_:)``, after this is set.
    private var outboundEncoderStream: OutboundEncoderStream?

    /// `nil` until ``outboundDecoderStreamReady(_:)`` supplies it, and never cleared afterwards.
    ///
    /// Force unwrapping is safe wherever the state machine hands us a decoder instruction: every one comes from
    /// `OutboundDecoderInstructionQueue.writeDecoderInstruction(_:)`, which buffers until its `noQueue` state, and
    /// that state is only entered from ``outboundDecoderStreamReady(_:)``, after this is set.
    private var outboundDecoderStream: OutboundDecoderStream?

    private var stateMachine: QPACKStateMachine<DecodeReceiver>

    private let connection: ConnectionDelegate

    /// Create a new ``QPACKCoder``.
    ///
    /// Both limits describe what this endpoint's decoder accepts from the peer's encoder, so they must match the
    /// `SETTINGS_QPACK_MAX_TABLE_CAPACITY` and `SETTINGS_QPACK_BLOCKED_STREAMS` this endpoint advertises.
    ///
    /// - Parameters:
    ///   - decoderMaxTableSize: Maximum size in bytes of this endpoint's dynamic table. `0` refuses it entirely.
    ///   - decoderMaxBlockedStreams: How many streams may be blocked at once waiting for entries which haven't
    ///     arrived on the peer's encoder stream yet. Exceeding this is a connection error.
    ///   - errorDelegate: Receives connection level errors and the request for an outbound encoder stream.
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
    /// If the peer advertised a zero sized dynamic table no encoder stream is requested, since it would never be
    /// used. See RFC 9204 § 4.2.
    ///
    /// - Important: The peer may only send SETTINGS once. Calling this a second time leaves the coder's state
    ///   untouched and reports an `H3_FRAME_UNEXPECTED` connection error to the ``ConnectionDelegate``.
    ///
    /// - Parameters:
    ///   - maxQueueSize: The peer's `SETTINGS_QPACK_BLOCKED_STREAMS`.
    ///   - effectiveDynamicTableSize: The peer's `SETTINGS_QPACK_MAX_TABLE_CAPACITY`.
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
        case .emitConnectionError(let error):
            self.connection.connectionError(error)
        case .none:
            break
        }
    }

    // MARK: Encode

    /// QPACK encode your HTTP fields. If new instructions need to be send to the peer as a side-effect of the encode the
    /// QPACKCoder will inform the ``QPACKOutboundEncoderStream`` via the ``QPACKOutboundEncoderStream/sendInstructions(_:)``
    /// method call.
    ///
    /// Use this method for headers and trailers.
    ///
    /// - Important: The returned field section references the dynamic table as it stands now, so it must be written
    ///   to the stream in the order it was encoded. Otherwise the peer's decoder sees references it can't resolve.
    ///
    /// - Returns: The encoded field section, ready to be framed as a HEADERS frame.
    @_spi(PackageInternal)
    public func encodeHeaders(_ fields: [HTTPField], streamID: QUICStreamID) -> HTTP3PartialFrame.Headers {
        let result = self.stateMachine.encodeHeaders(fields, forStream: streamID)

        if !result.instructions.isEmpty {
            // Safe to unwrap: instructions imply the encoder is using the dynamic table, which it only does once
            // the stream is set. See `outboundEncoderStream`.
            self.outboundEncoderStream!.sendInstructions(result.instructions)
        }

        return HTTP3PartialFrame.Headers(fieldSection: result.fieldSection)
    }

    /// Call this method as a response to the ``ConnectionDelegate/makeOutboundEncoderStream()``
    /// invocation with a stream that conforms to the ``QPACKOutboundEncoderStream``
    /// protocol.
    ///
    /// The coder writes a `Set Dynamic Table Capacity` instruction on the new stream and starts encoding with the
    /// dynamic table.
    ///
    /// - Precondition: Call this only after ``ConnectionDelegate/makeOutboundEncoderStream()`` asked for the
    ///   stream, and only once.
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
    /// Section acknowledgements, stream cancellations and insert count increments tell this endpoint's encoder
    /// which of its dynamic table entries the peer has seen, which is what lets the encoder evict them. An
    /// instruction received while the dynamic table isn't in use, or one that doesn't match the encoder's state,
    /// is a `QPACK_DECODER_STREAM_ERROR` connection error.
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

    /// Decode incoming HTTP fields. Use this method for headers and trailers.
    ///
    /// This method does not return the decoded http fields syncronously, as decoding might depend
    /// on decoder instructions that arrive asyncronously via ``receivedIncomingDecoderInstruction(_:)``
    ///
    /// If the field section references dynamic table entries which haven't arrived yet the stream blocks, and the
    /// decode completes later from ``receivedIncomingEncoderInstruction(_:)``. Blocking more streams than the
    /// `decoderMaxBlockedStreams` promised at init is a connection error.
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
    /// Decoder instructions produced before this point are buffered, and are all written here.
    ///
    /// - Precondition: Call this at most once.
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
    /// These instructions maintain this endpoint's dynamic table. Applying one can unblock any number of waiting
    /// field sections, and each of their ``QPACKDecodeReceiver``s is called synchronously from here, in ascending
    /// order of required insert count. An instruction the decoder can't apply is a `QPACK_ENCODER_STREAM_ERROR`
    /// connection error.
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

        // One instruction can unblock several streams. Terminates because every non-nil result pops an entry.
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
    ///   - seenEOF: `true` if every field section on the stream was processed. If `false`, some may never be
    ///     acknowledged, so the peer's encoder is told to stop expecting acks. See RFC 9204 § 2.2.2.2.
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

@available(*, unavailable)
extension QPACKCoder: Sendable {}
