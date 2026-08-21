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

package import struct NIOCore.ByteBuffer

/// Calls the decoder, and buffers bytes until a frame is ready.
///
/// Call readBytes to give the decoder some bytes.
/// Call decodeNext to get back one HTTP3PartialFrame at a time.
/// This does not handle QPACK at all, hence returning partial frames.
package struct HTTP3FrameDecoderStateMachine: ~Copyable {
    enum State: ~Copyable {
        /// We have no unprocessed bytes.
        case idle

        /// We have received some bytes but haven't been able to make a frame from them yet.
        case decoding(Decoding)

        /// We previously hit an error, we'll not do anything further now.
        case previousError

        struct Decoding: ~Copyable {
            /// The bytes which haven't been processed yet.
            var buffer: ByteBuffer
            /// The decoder we are using. This holds state about bytes it's already seen.
            var decoder: HTTP3FrameDecoder

            /// Decodes a single frame from the buffer and reclaims already-read bytes if worthwhile.
            ///
            /// - Returns: The decoded frame, or `nil` if more bytes are needed.
            /// - Throws: ``HTTP3Error`` propagated from the underlying ``HTTP3FrameDecoder``. This should be treated as
            ///   a connection-level error.
            mutating func decode() throws(HTTP3Error) -> HTTP3PartialFrameOrUnknown? {
                let result = try self.decoder.decode(buffer: &self.buffer)

                // We attempt to reclaim already-read bytes *after* decoding. Attempting to reclaim *before* decoding
                // would result in unnecessary copying of bytes that the decoder is about to consume.
                self.reclaimBytesIfWorthwhile()

                return result
            }

            /// Whether the buffer has enough already-read bytes to justify reclaiming them.
            ///
            /// - Returns: `true` if the buffer is at least 1kB in size and already-read bytes occupy over 50% of its
            ///   capacity.
            private func isWorthwhileToReclaimBytes() -> Bool {
                // Over 50% of the buffer's capacity is occupied by already-read bytes. These dead bytes leave little
                // writable capacity in the buffer, so appending further incoming bytes will likely trigger a
                // reallocation. Now is a good time to discard them so that a future reallocation may be avoided.
                self.buffer.capacity > 1024 && (self.buffer.readerIndex > (self.buffer.capacity / 2))
            }

            /// Reclaims already-read bytes from the buffer if `isWorthwhileToReclaimBytes()` returns `true`.
            private mutating func reclaimBytesIfWorthwhile() {
                if self.isWorthwhileToReclaimBytes() {
                    self.buffer.discardReadBytes()
                }
            }
        }
    }

    private let state: State

    package init() {
        self.init(state: .idle)
    }

    private init(state: consuming State) {
        self.state = state
    }

    /// Put bytes into the decoder. To get the resulting frames, call decodeNext.
    package mutating func buffer(_ buffer: ByteBuffer) {
        switch consume self.state {
        case .idle:
            let decoder = HTTP3FrameDecoder()
            self = .init(state: .decoding(.init(buffer: buffer, decoder: decoder)))
        case .decoding(var decodingState):
            decodingState.buffer.writeImmutableBuffer(buffer)
            self = .init(state: .decoding(decodingState))
        case .previousError:
            // Ignore the new bytes. We aren't doing anything anymore
            self = .init(state: .previousError)
            return
        }
    }

    enum DecodeAction {
        /// A frame has been read from the incoming bytes. You should call decodeNext() again to check if there are more frames available.
        case returnFrame(HTTP3PartialFrame)
        /// A frame of unknown type has been read from the incoming bytes. You should call decodeNext() again to check if there are more frames available.
        case returnUnknownFrame
        /// There are not enough bytes to form a full frame. There may or may not be any bytes at all in buffer. You should call decodeNext again after buffering more bytes.
        case needMoreBytes
        /// An error was hit (e.g. malformed frame).
        case emitConnectionError(HTTP3Error)
        /// We previously emitted an error so are now unable to process further frames
        case previousError
    }

    /// Read out one decoded frame from the bytes previously put into the decoder.
    /// Call this in a loop to get all frames, until it returns none.
    mutating func decodeNext() -> DecodeAction {
        switch consume self.state {
        case .decoding(var decodingState):
            do {
                let result = try decodingState.decode()
                self = .init(state: .decoding(decodingState))
                switch result {
                case .known(let frame):
                    return .returnFrame(frame)
                case .unknown:
                    return .returnUnknownFrame
                case .none:
                    // no frames available yet. We need more bytes
                    return .needMoreBytes
                }
            } catch {
                // A malformed frame is a connection error
                self = .init(state: .previousError)
                return .emitConnectionError(error)
            }
        case .idle:
            self = .init(state: .idle)
            return .needMoreBytes
        case .previousError:
            self = .init(state: .previousError)
            return .previousError
        }
    }

    /// Mark the input as closed.
    /// This consumes the state machine: you cannot do anything after closing the input.
    /// - Returns: True if there were buffered bytes which hadn't been used yet, which have now been lost.
    package consuming func inputClosed() -> Bool {
        switch consume self.state {
        case .idle:
            return false
        case .decoding(let decodingState):
            if decodingState.buffer.readableBytes == 0 {
                // We don't have anything buffered here but the decoder itself might.
                return decodingState.decoder.hasPartialFrame
            } else {
                return true
            }
        case .previousError:
            // Since we already hit an error, further errors are moot
            return false
        }
    }
}

// Test accessors.
extension HTTP3FrameDecoderStateMachine {
    /// The buffer used in the decoding state, or `nil` if not in the decoding state.
    private var _testOnlyBuffer: ByteBuffer? {
        switch self.state {
        case .decoding(let decodingState):
            return decodingState.buffer

        case .idle:
            return nil

        case .previousError:
            return nil
        }
    }

    /// The decoding buffer's `readerIndex`, or `nil` if not in the decoding state.
    /// - Note: This property is only intended to be used in tests.
    package var _testOnlyBufferReaderIndex: Int? {
        self._testOnlyBuffer?.readerIndex
    }

    /// The decoding buffer's `writerIndex`, or `nil` if not in the decoding state.
    /// - Note: This property is only intended to be used in tests.
    package var _testOnlyBufferWriterIndex: Int? {
        self._testOnlyBuffer?.writerIndex
    }

    /// The decoding buffer's `capacity`, or `nil` if not in the decoding state.
    /// - Note: This property is only intended to be used in tests.
    package var _testOnlyBufferCapacity: Int? {
        self._testOnlyBuffer?.capacity
    }
}
