//
//  QPACKCoder.swift
//  swift-nio-http3
//
//  Created by Fabian Fett on 26.08.26.
//

@_spi(PackageInternal) public import QPACK
public import NIOQUICHelpers
public import HTTPTypes

/// A stream to send encoder instructions on, which the peer can then use in its QPACKDecoder
@_spi(PackageInternal)
public protocol QPACKOutboundEncoderStream: ~Copyable {
    func sendInstructions(_ instructions: some Collection<QPACKEncoderInstruction>)
}

/// A stream to send decoder acknowledgements, stream cancellations and insert count increments on.
@_spi(PackageInternal)
public protocol QPACKOutboundDecoderStream: ~Copyable {
    func sendInstruction(_ instruction: QPACKDecoderInstruction)
    func sendInstructions(_ instruction: some Collection<QPACKDecoderInstruction>)
}

/// A object representing an HTTP3Connection to forward connection level errors to.
@_spi(PackageInternal)
public protocol ConnectionDelegate {
    func connectionError(_ error: HTTP3Error)
    func makeOutboundEncoderStream()
}

/// A object that is interested in the async QPACK decode result. In most cases this will be an object representing
/// a HTTP3 stream.
@_spi(PackageInternal)
public protocol QPACKDecodeReceiver {
    /// Inform the QPACKDecodeReceiver that a decode has happened.
    ///
    /// - Important: If the decoder has all the necessary QPACK decode information available the decoder
    ///              will invoke this method syncronously from
    ///              ``QPACKCoder/decodeHeaders(_:streamID:decodeReceiver:)``.
    func decodeResult(_ result: Result<[HTTPField], any Error>)
}

/// An object encapsulating all the QPACK encoding and decoding. It implements the QPACK procedures while being
/// abstract about the implementations that drive the QPACK coding.
@_spi(PackageInternal)
public final class QPACKCoder<
    OutboundEncoderStream: QPACKOutboundEncoderStream & ~Copyable,
    OutboundDecoderStream: QPACKOutboundDecoderStream & ~Copyable,
    ConnectionDelegate: HTTP3.ConnectionDelegate,
    DecodeReceiver: QPACKDecodeReceiver
> {

    private var outboundEncoderStream: OutboundEncoderStream?

    private var outboundDecoderStream: OutboundDecoderStream?

    private var stateMachine: QPACKStateMachine<DecodeReceiver>

    private let connection: ConnectionDelegate

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
    @_spi(PackageInternal)
    public func encodeHeaders(_ fields: [HTTPField], streamID: QUICStreamID) -> HTTP3PartialFrame.Headers {
        let result = self.stateMachine.encodeHeaders(fields, forStream: streamID)

        if !result.instructions.isEmpty {
            self.outboundEncoderStream!.sendInstructions(result.instructions)
        }

        return HTTP3PartialFrame.Headers(fieldSection: result.fieldSection)
    }

    /// Call this method as a response to the ``ConnectionDelegate/makeOutboundEncoderStream()``
    /// invocation with a stream that conforms to the ``QPACKOutboundEncoderStream``
    /// protocol.
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
    /// - Important: If the decoder has all the necessary QPACK decode information available the decoder
    ///              will invoke the ``QPACKDecodeReceiver/decodeResult(_:)`` method syncronously.
    ///
    /// - Parameters:
    ///   - fields: The headers to QPACK decode
    ///   - streamID: The stream id of the stream, that received the header frame
    ///   - decodeReceiver: The object that needs to be informed about the decode result.
    @_spi(PackageInternal)
    public func decodeHeaders(_ headers: HTTP3PartialFrame.Headers, streamID: QUICStreamID, decodeReceiver: DecodeReceiver) {
        let action = self.stateMachine.decodeHeaders(headers, forStream: streamID, context: decodeReceiver)
        self.runDecodeHeaderAction(action)
    }

    /// Call this method as soon as the outbound decoder stream has been created after connection
    /// creation.
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

    /// Call this method as soon as the incoming encoder stream has been created after connection
    /// creation.
    @_spi(PackageInternal)
    public func receivedIncomingEncoderInstruction(
        _ instruction: QPACKEncoderInstruction
    ) {
        let action = self.stateMachine.receivedIncomingEncoderInstruction(instruction)
        switch action {
        case .sendDecoderInstruction(let qPACKDecoderInstruction):
            self.outboundDecoderStream!.sendInstruction(qPACKDecoderInstruction)
        case .emitConnectionError(let http3Error):
            self.connection.connectionError(http3Error)
        case .none:
            break
        }

        self.runDecodeHeaderAction(self.stateMachine.checkPendingDecodes())
    }

    private func runDecodeHeaderAction(_ action: QPACKStateMachine<DecodeReceiver>.DecodeHeaderAction?) {
        switch action {
        case .informDecodeResult(let result, let receiver):
            if let instruction = result.instructionToWrite {
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
    @_spi(PackageInternal)
    public func requestStreamClosed(streamID: QUICStreamID, seenEOF: Bool) {
        switch self.stateMachine.requestStreamClosed(streamID: streamID, seenEOF: seenEOF) {
        case .sendDecoderInstruction(let instruction):
            self.outboundDecoderStream!.sendInstruction(instruction)
        case .none:
            break
        }
    }
}
