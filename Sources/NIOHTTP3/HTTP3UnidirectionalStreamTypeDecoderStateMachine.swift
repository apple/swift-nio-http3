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

package import struct NIOCore.ByteBuffer

/// This state machine helps to decode the type of an incoming unidirectional stream.
/// The first bytes received on the stream tell us the type of the stream (they form a length-prefixed integer).
/// You should call buffer for any incoming data.
/// The state machine will read data until a type is found, and then return the `gotStreamType` action.
/// You should continue calling buffer for incoming bytes after the stream type is found.
/// Once you know the type, and have set up downstream handlers accordingly, you must call `unbufferElement` to get the bytes out from this state machines buffers.
/// `unbufferElement` must be called repeatedly until it returns nil.
/// Once it returns nil, no method on this state machine should ever be called again, and the handler holding it should be removed from the pipeline.
package struct HTTP3UnidirectionalStreamTypeDecoderStateMachine: ~Copyable {
    private enum State: ~Copyable {
        /// Nothing has happened yet. We don't know the stream type.
        case idle
        /// We read some bytes, but not enough to work out the stream type. The ones we have read so far are buffered here.
        case readIncompleteStreamType(buffer: ByteBuffer)
        /// We have read the stream type, but haven't yet been told to release the queue. So we buffer incoming data.
        case buffering(queue: Deque<ByteBuffer>)
        /// We released the entire queue. We are done.
        case done
        /// We decided to drop all incoming data. This would happen if the stream type is unknown
        case droppingIncomingData
    }

    private let state: State

    package init() {
        self.init(state: .idle)
    }

    private init(state: consuming State) {
        self.state = state
    }

    package enum UnbufferAction: Hashable {
        /// The given bytebuffer should be fired down the pipeline.
        case release(ByteBuffer)
        /// There is nothing left in the queue. You should not call any method on this state machine again.
        case done
    }

    /// Returns ByteBuffers which were previously buffered behind the stream type.
    /// Call this method when the pipeline beneath this handler is ready to receive data according to the stream type.
    /// Do not call before stream type is known.
    /// Call this in a loop until .done is returned.
    /// Do not call after .done is returned.
    package mutating func unbufferElement() -> UnbufferAction {
        switch consume self.state {
        case .readIncompleteStreamType:
            fatalError("Can't unbuffer element before knowing the stream type")
        case .idle:
            fatalError("Can't unbuffer element before knowing the stream type")
        case .buffering(var queue):
            if let nextItem = queue.popFirst() {
                self = .init(state: .buffering(queue: queue))
                return .release(nextItem)
            } else {
                self = .init(state: .done)
                return .done
            }
        case .done:
            fatalError("unbufferElement called after done was returned!")
        case .droppingIncomingData:
            fatalError("unbufferElement called when dropping data!")
        }
    }

    package mutating func abortReading() {
        switch consume self.state {
        case .readIncompleteStreamType:
            fatalError("Can't abort reading before knowing the stream type")
        case .idle:
            fatalError("Can't abort reading before knowing the stream type")
        case .buffering:
            self = .init(state: .droppingIncomingData)
        case .done:
            fatalError("abortReading called after unbufferElement!")
        case .droppingIncomingData:
            fatalError("abortReading called twice!")
        }
    }

    enum ChannelReadAction: Hashable {
        /// Stream type should be sent to the callback.
        case gotStreamType(HTTP3StreamType.Unidirectional)
    }

    /// The handler has received data.
    mutating func buffer(data: ByteBuffer) -> ChannelReadAction? {
        switch consume self.state {
        case .idle:
            // No existing queue, no existing stream type. Try to get it.
            let next = Self.channelReadTryGetType(data: data)
            self = .init(state: next.nextState)
            return next.action
        case .readIncompleteStreamType(var existingBuffer):
            // We have existing buffer containing part of the stream type. Append the new data to that
            existingBuffer.writeImmutableBuffer(data)
            let next = Self.channelReadTryGetType(data: existingBuffer)
            self = .init(state: next.nextState)
            return next.action
        case .buffering(var queue):
            // Already have a queue, already know the stream type. Just add to the queue
            queue.append(data)
            self = .init(state: .buffering(queue: queue))
            return .none
        case .done:
            // This state should not be reachable because this channel handler is removed when the queue is done
            fatalError("Should not receive data after queue finished")
        case .droppingIncomingData:
            // This state should not be reachable because the input is closed when we reset the stream
            fatalError("Should not receive data after aborted stream")
        }
    }

    private struct StateAndAction: ~Copyable {
        var nextState: State
        var action: ChannelReadAction?

        init(nextState: consuming State, action: ChannelReadAction?) {
            self.nextState = nextState
            self.action = action
        }
    }

    /// Tries to get the type out of the given data. If successful, buffers the _rest_ of the data in the queue.
    /// If unsuccessful, buffers _all_ of the data as a partial stream type to be parsed when we have more data.
    private static func channelReadTryGetType(
        data: ByteBuffer
    ) -> StateAndAction {
        var data = data
        // This will move the reader index past the stream type only on a successful read
        if let typeInteger = data.readEncodedInteger(as: UInt64.self, strategy: .quic) {
            let streamType = HTTP3StreamType.Unidirectional(rawValue: typeInteger)
            let nextState =
                if data.readableBytes == 0 {
                    // There are no bytes in the buffer beyond the stream type, so our queue is empty
                    State.buffering(queue: [])
                } else {
                    // There are bytes in the buffer after the stream type. We need to keep those
                    State.buffering(queue: [data])
                }
            let action = ChannelReadAction.gotStreamType(streamType)
            return .init(nextState: nextState, action: action)
        } else {
            // We don't have enough data yet
            let nextState = State.readIncompleteStreamType(buffer: data)
            return .init(nextState: nextState, action: nil)
        }
    }
}
