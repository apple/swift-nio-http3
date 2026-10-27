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
public import HTTPTypes
public import NIOQUICHelpers

enum QPACKEncoderError: Error, Sendable, Hashable {
    case unknownStream
    case unexpectedStreamAck
}

struct StreamTrackerMessage {
    /// All the dynamic table indices referenced by this message. Must not be empty.
    var dynamicTableIndices: [Int]
    /// The required insert count for the decoder to be able to decode this message. This will typically be 1 lower (because of 0-based indexing) than the highest index in the array above.
    var requiredInsertCount: Int
}

/// Used for tracking which streams are using which dynamic table indices. This is useful for knowing when to
/// consider entries as acknowledged, and knowing when they're evictable.
struct StreamTracker {
    struct Stream {
        /// A deque of Messages sent on the stream which haven't been acked.
        private var underlying: Deque<StreamTrackerMessage> = .init(minimumCapacity: 1)

        /// The required insert count for all messages on this stream to become unblocked.
        var requiredInsertCount: Int = 0

        var isEmpty: Bool {
            self.underlying.isEmpty
        }

        /// Get the oldest unacknowledged message for this stream and pop it.
        mutating func nextMessage() -> StreamTrackerMessage? {
            self.underlying.popFirst()
        }

        /// Record that this stream has sent something containing dynamic table references.
        mutating func recordSendMessage(_ message: StreamTrackerMessage) {
            assert(!message.dynamicTableIndices.isEmpty)
            self.requiredInsertCount = max(self.requiredInsertCount, message.requiredInsertCount)
            self.underlying.append(message)
        }
    }

    private var streams = [QUICStreamID: Stream]()

    func potentiallyBlockedStreams(knownInsertCount: Int, excluding keyToExclude: QUICStreamID) -> Int {
        let result = self.streams.reduce(into: 0) { acc, item in
            if item.key != keyToExclude && item.value.requiredInsertCount > knownInsertCount {
                acc += 1
            }
        }
        return result
    }

    /// Remove a stream from the tracker.
    /// - Parameter id: ID of the stream to remove.
    /// - Returns: The stream which was removed.
    @discardableResult
    mutating func removeStream(withID id: QUICStreamID) -> Stream? {
        self.streams.removeValue(forKey: id)
    }

    /// Retrieve and pop the oldest un-acked message for a given stream ID.
    mutating func nextMessage(forStream id: QUICStreamID) throws(QPACKEncoderError) -> StreamTrackerMessage? {
        guard var stream = self.streams.removeValue(forKey: id) else {
            // If an encoder receives a Section Acknowledgment instruction referring to a stream on which every
            // encoded field section with a non-zero Required Insert Count has already been acknowledged,
            // this MUST be treated as a connection error of type QPACK_DECODER_STREAM_ERROR.
            throw QPACKEncoderError.unexpectedStreamAck
        }
        defer {
            self.streams[id] = stream
        }
        return stream.nextMessage()
    }

    mutating func removeIfEmpty(streamID: QUICStreamID) throws(QPACKEncoderError) {
        guard let stream = self.streams[streamID] else {
            throw QPACKEncoderError.unknownStream
        }

        if stream.isEmpty {
            self.removeStream(withID: streamID)
        }
    }

    mutating func recordSentMessage(_ message: StreamTrackerMessage, forStream streamID: QUICStreamID) {
        var existingStream = self.streams.removeValue(forKey: streamID) ?? .init()
        existingStream.recordSendMessage(message)
        self.streams[streamID] = existingStream
    }
}

@available(anyAppleOS 27, *)
@_spi(PackageInternal)
public struct QPACKEncodeResult: Sendable, Hashable {
    @_spi(PackageInternal)
    public let fieldSection: FieldSection
    @_spi(PackageInternal)
    public let instructions: [QPACKEncoderInstruction]

    @_spi(PackageInternal)
    public init(fieldSection: FieldSection, instructions: [QPACKEncoderInstruction]) {
        self.fieldSection = fieldSection
        self.instructions = instructions
    }
}

/// A bit like ``FieldLine`` but without caring about wire representation.
@available(anyAppleOS 27, *)
enum HeaderRepresentation {
    case literal(requireLiteralRepresentation: Bool, name: HTTPField.Name, value: String)
    case staticTableReference(index: Int)
    case staticTableNameReference(requireLiteralRepresentation: Bool, index: Int, value: String)
    case dynamicTableReference(absoluteIndex: Int)
    case dynamicTableNameReference(requireLiteralRepresentation: Bool, absoluteIndex: Int, value: String)

    var requiredIndex: Int? {
        switch self {
        case .literal, .staticTableReference, .staticTableNameReference: return nil
        case .dynamicTableReference(let absoluteIndex): return absoluteIndex
        case .dynamicTableNameReference(_, let absoluteIndex, _): return absoluteIndex
        }
    }

    func asFieldLine(base: Int) -> FieldLine {
        switch self {
        case .literal(let requireLiteralRepresentation, let name, let value):
            return .literal(
                requireLiteralRepresentation: requireLiteralRepresentation,
                name: name.canonicalName,
                value: value
            )
        case .staticTableReference(let index):
            return .indexed(.staticTable, index: index)
        case .staticTableNameReference(let requireLiteralRepresentation, let index, let value):
            return .literalWithNameReference(
                requireLiteralRepresentation: requireLiteralRepresentation,
                table: .staticTable,
                index: index,
                value: value
            )
        case .dynamicTableReference(let absoluteIndex):
            if absoluteIndex >= base {
                // starting at 0 for the entry with absolute index equal to Base and increasing in the same direction as the absolute index.
                let relativeIndex = absoluteIndex - base
                return .indexedWithPostBase(index: relativeIndex)
            } else {
                // 0 refers to the entry with absolute index equal to Base - 1 and increasing in the opposite direction as the absolute index.
                let relativeIndex = base - absoluteIndex - 1
                return .indexed(.dynamicTable, index: relativeIndex)
            }
        case .dynamicTableNameReference(let requireLiteralRepresentation, let absoluteIndex, let value):
            if absoluteIndex >= base {
                // starting at 0 for the entry with absolute index equal to Base and increasing in the same direction as the absolute index.
                let relativeIndex = absoluteIndex - base
                return .literalWithNameReferenceWithPostBase(
                    requireLiteralRepresentation: requireLiteralRepresentation,
                    index: relativeIndex,
                    value: value
                )
            } else {
                // 0 refers to the entry with absolute index equal to Base - 1 and increasing in the opposite direction as the absolute index.
                let relativeIndex = base - absoluteIndex - 1
                return .literalWithNameReference(
                    requireLiteralRepresentation: requireLiteralRepresentation,
                    table: .dynamicTable,
                    index: relativeIndex,
                    value: value
                )
            }
        }
    }
}
