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
private enum HeaderRepresentation {
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

/// The result of encoding a single line. Contains the encoded form of the line + the instruction needed, if any.
private struct QPACKEncodeSingleResult {
    let headerRepresentation: HeaderRepresentation
    let instruction: QPACKEncoderInstruction?

    init(headerRepresentation: HeaderRepresentation, instruction: QPACKEncoderInstruction?) {
        self.headerRepresentation = headerRepresentation
        self.instruction = instruction
    }
}

/// A full QPACK encoder which may use the dynamic table and may emit instructions.
@_spi(PackageInternal)
public struct DynamicQPACKEncoder {
    /// The actual header table.
    private var table: DynamicHeaderTable
    /// The maximum number of streams we'll risk blocking. The peers decoder chooses this.
    private let maxBlockedStreams: Int
    /// For tracking which streams use which table entries, for eviction purposes and for monitoring which streams might be blocked.
    private var streamTracker: StreamTracker
    /// For when the dynamic table can't be used (e.g. it's full).
    private let staticEncoder: StaticQPACKEncoder

    @_spi(PackageInternal)
    public static func create(
        dynamicTableMaxCapacity: Int,
        dynamicTableInitialCapacity: Int,
        maxBlockedStreams: Int,
        targetEvictableFraction: Double
    ) -> (Self, QPACKEncoderInstruction?) {
        assert(dynamicTableMaxCapacity >= 0)
        let dynamicTableMaxCapacity = max(dynamicTableMaxCapacity, 0)
        // In debug mode, we'll enforce the constraint, otherwise we'll correct the mistake
        assert(dynamicTableInitialCapacity <= dynamicTableMaxCapacity)
        assert(dynamicTableInitialCapacity >= 0)
        let dynamicTableInitialCapacity = max(min(dynamicTableInitialCapacity, dynamicTableMaxCapacity), 0)
        let table = DynamicHeaderTable(
            maximumCapacity: dynamicTableMaxCapacity,
            initialCapacity: dynamicTableInitialCapacity,
            targetEvictableFraction: targetEvictableFraction,
            assumeAllEntriesReceived: false
        )
        let result: QPACKEncoderInstruction?
        if dynamicTableInitialCapacity != 0 {
            result = .setDynamicTableCapacity(dynamicTableInitialCapacity)
        } else {
            result = nil
        }
        let encoder = Self(
            table: table,
            maxBlockedStreams: maxBlockedStreams,
            streamTracker: .init(),
            staticEncoder: .init()
        )
        return (encoder, result)
    }

    @_spi(PackageInternal)
    public mutating func encode(headers: [HTTPField], forStream streamID: QUICStreamID) -> QPACKEncodeResult {
        let base = self.table.insertCount
        var highestRequiredIndex: Int?
        var requiredIndices = [Int]()
        var instructions = [QPACKEncoderInstruction]()
        // At most, each header can require one instruction
        instructions.reserveCapacity(headers.count)
        let lines = headers.map { header in
            let encodeResult =
                switch header.indexingStrategy {
                case .avoid:
                    // We want to avoid using the dynamic table, but not block intermediates from doing so
                    QPACKEncodeSingleResult(
                        headerRepresentation: self.staticEncoder.encodeSingleHeader(
                            header,
                            requireLiteralRepresentation: false
                        ),
                        instruction: nil
                    )
                case .disallow:
                    // We must prevent intermediates from adding this to the table
                    QPACKEncodeSingleResult(
                        headerRepresentation: self.staticEncoder.encodeSingleHeader(
                            header,
                            requireLiteralRepresentation: true
                        ),
                        instruction: nil
                    )
                case .prefer, .automatic, _:
                    self.encodeSingleHeader(
                        header,
                        streamID: streamID,
                        maxBlockedStreams: self.maxBlockedStreams
                    )
                }
            let encoded = encodeResult.headerRepresentation
            if let ins = encodeResult.instruction {
                instructions.append(ins)
            }
            if let requiredIndex = encoded.requiredIndex {
                requiredIndices.append(requiredIndex)
                if let existing = highestRequiredIndex {
                    highestRequiredIndex = max(existing, requiredIndex)
                } else {
                    highestRequiredIndex = requiredIndex
                }
            }
            return encoded.asFieldLine(base: base)
        }
        // insert count is one more than absolute index
        let requiredInsertCount = highestRequiredIndex.map { $0 + 1 } ?? 0
        if !requiredIndices.isEmpty {
            self.streamTracker.recordSentMessage(
                StreamTrackerMessage(
                    dynamicTableIndices: requiredIndices,
                    requiredInsertCount: requiredInsertCount
                ),
                forStream: streamID
            )
        }
        let prefix = FieldSectionPrefix(requiredInsertCount: requiredInsertCount, base: base)
        let encodedPrefix = prefix.encode(maxCapacity: self.table.maximumCapacity)
        return .init(fieldSection: .init(prefix: encodedPrefix, lines: lines), instructions: instructions)
    }

    /// - Parameters:
    ///   - header: The header to be encoded.
    ///   - streamID: The stream we're encoding for.
    ///   - maxBlockedStreams: How many streams may be blocked at once. Avoid blocking further streams if it'll go over this number.
    /// - Returns: The encoded header.
    private mutating func encodeSingleHeader(
        _ header: HTTPField,
        streamID: QUICStreamID,
        maxBlockedStreams: Int
    ) -> QPACKEncodeSingleResult {
        let requireLiteralRepresentation = false
        let staticTableEntry = StaticHeaderTable.find(name: header.name, value: header.value)
        if let staticTableEntry, staticTableEntry.containsValue {
            // Exact match in static table
            return .init(headerRepresentation: .staticTableReference(index: staticTableEntry.index), instruction: nil)
        }
        let potentiallyBlockedStreams = self.streamTracker.potentiallyBlockedStreams(
            knownInsertCount: self.table.knownReceivedCount,
            excluding: streamID  // Blocking the same stream further is OK if it is already blocked
        )
        let avoidBlocking = potentiallyBlockedStreams >= maxBlockedStreams

        let dynamicTableEntry = self.table.findExistingHeader(named: header.name, value: header.value)

        if let dynamicTableEntry, dynamicTableEntry.containsValue {
            // Exact match in dynamic table
            if dynamicTableEntry.isNearingEviction {
                // duplicate the entry
                // If we need to avoid blocking then fallthrough to logic below, the match is unusable
                if !avoidBlocking {
                    do {
                        let duplicatedAbsoluteIndex = try self.table.addHeader(
                            named: header.name,
                            value: header.value
                        )
                        self.table.addReference(duplicatedAbsoluteIndex)
                        return .init(
                            headerRepresentation: .dynamicTableReference(absoluteIndex: duplicatedAbsoluteIndex),
                            instruction: .duplicateEntry(relativeIndex: dynamicTableEntry.relativeIndex)
                        )
                    } catch {
                        switch error {
                        case .cannotPurge, .insufficientStorage:
                            // There isn't enough room to duplicate
                            // Fallthrough to logic below, as if there was no dynamic table match
                            // Because the match is basically unusable
                            break
                        }
                    }
                }
            } else if dynamicTableEntry.isKnownReceived || !avoidBlocking {
                // If we need to avoid blocking then fallthrough to logic below, the match is unusable
                self.table.addReference(dynamicTableEntry.absoluteIndex)
                return .init(
                    headerRepresentation: .dynamicTableReference(absoluteIndex: dynamicTableEntry.absoluteIndex),
                    instruction: nil
                )
            }
        }
        // No exact matches in either table
        if let staticTableEntry {
            // Partial match in static table
            if avoidBlocking {
                // We need to avoid blocking so we use a literal
                return .init(
                    headerRepresentation: .staticTableNameReference(
                        requireLiteralRepresentation: requireLiteralRepresentation,
                        index: staticTableEntry.index,
                        value: header.value
                    ),
                    instruction: nil
                )
            }
            // If we're allowed to block then try adding the match to the dynamic table then return that reference
            do {
                let absoluteIndex = try self.table.addHeader(named: header.name, value: header.value)
                let instruction =
                    QPACKEncoderInstruction
                    .insertWithNameReference(
                        .staticTable,
                        relativeIndex: staticTableEntry.index,
                        value: header.value
                    )
                self.table.addReference(absoluteIndex)
                return .init(
                    headerRepresentation: .dynamicTableReference(absoluteIndex: absoluteIndex),
                    instruction: instruction
                )
            } catch {
                switch error {
                case .cannotPurge, .insufficientStorage:
                    // Couldn't add to dynamic table. Just send it as a literal value with the static table name reference
                    return .init(
                        headerRepresentation: .staticTableNameReference(
                            requireLiteralRepresentation: requireLiteralRepresentation,
                            index: staticTableEntry.index,
                            value: header.value
                        ),
                        instruction: nil
                    )
                }
            }
        } else if let dynamicTableEntry, !dynamicTableEntry.isNearingEviction,
            dynamicTableEntry.isKnownReceived || !avoidBlocking
        {
            // Partial match in dynamic table
            // We'll reference the existing entry with a literal value
            self.table.addReference(dynamicTableEntry.absoluteIndex)
            return .init(
                headerRepresentation: .dynamicTableNameReference(
                    requireLiteralRepresentation: requireLiteralRepresentation,
                    absoluteIndex: dynamicTableEntry.absoluteIndex,
                    value: header.value
                ),
                instruction: nil
            )
        } else {
            // It's not in any table. Let's add to dynamic table if we can
            if avoidBlocking {
                return .init(
                    headerRepresentation: .literal(
                        requireLiteralRepresentation: false,
                        name: header.name,
                        value: header.value
                    ),
                    instruction: nil
                )
            }
            do {
                let absoluteIndex = try self.table.addHeader(named: header.name, value: header.value)
                self.table.addReference(absoluteIndex)
                return .init(
                    headerRepresentation: .dynamicTableReference(absoluteIndex: absoluteIndex),
                    instruction: .insertWithLiteralName(name: header.name.canonicalName, value: header.value)
                )
            } catch {
                switch error {
                case .cannotPurge, .insufficientStorage:
                    // Couldn't add to table. Let's send a literal instead
                    return .init(
                        headerRepresentation: .literal(
                            requireLiteralRepresentation: false,
                            name: header.name,
                            value: header.value
                        ),
                        instruction: nil
                    )
                }
            }
        }
    }

    @_spi(PackageInternal)
    public mutating func processInstruction(
        _ instruction: QPACKDecoderInstruction
    ) throws {
        switch instruction {
        case .insertCountIncrement(let increment):
            try self.table.insertCountIncrement(by: increment)
        case .sectionAcknowledgement(let streamID):
            // all dynamic table entries used in this section are now implicitly acked
            guard let message = try self.streamTracker.nextMessage(forStream: streamID) else {
                // If an encoder receives a Section Acknowledgment instruction referring to a stream on which every
                // encoded field section with a non-zero Required Insert Count has already been acknowledged,
                // this MUST be treated as a connection error of type QPACK_DECODER_STREAM_ERROR.
                throw QPACKEncoderError.unexpectedStreamAck
            }
            try self.acknowledgeMessage(message, incrementKnownReceivedCount: true)
            try self.streamTracker.removeIfEmpty(streamID: streamID)
        case .streamCancellation(let streamID):
            // all dynamic table entries used in this section are now implicitly acked
            if var stream = self.streamTracker.removeStream(withID: streamID) {
                while let message = stream.nextMessage() {
                    // incrementKnownReceivedCount is false because the message wasn't necessarily read
                    // See 9204 § 2.2.2.2: An encoder cannot infer from this instruction that any updates to the dynamic table have been received
                    try self.acknowledgeMessage(message, incrementKnownReceivedCount: false)
                }
            }
        }
    }

    private mutating func acknowledgeMessage(
        _ message: StreamTrackerMessage,
        incrementKnownReceivedCount: Bool
    ) throws {
        // When the stream is acknowledged or cancelled by the decoder, we need to decrease the ref count for the entries used
        // Also, the highest entry amongst them becomes the known received count
        var highestAbsoluteIndex: Int?
        for absoluteIndex in message.dynamicTableIndices {
            if highestAbsoluteIndex == nil || highestAbsoluteIndex! < absoluteIndex {
                highestAbsoluteIndex = absoluteIndex
            }
            self.table.removeReference(absoluteIndex)
        }
        if let highestAbsoluteIndex {
            let insertCount = highestAbsoluteIndex + 1  // indices are from 0, so the count is one more
            if incrementKnownReceivedCount {
                try self.table.acknowledgeInsertCount(insertCount)
            }
        } else {
            assertionFailure("Stream tracker should not track messages which don't use dynamic table")
        }
    }
}

/// Can encode field sections but only statically (can't use dynamic table and can't send instructions).
@_spi(PackageInternal)
public struct StaticQPACKEncoder {
    @_spi(PackageInternal)
    public init() {}

    @_spi(PackageInternal)
    public func encode(headers: [HTTPField]) -> FieldSection {
        let base = 0  // base 0 is the cheapest way when no dynamic entries
        var lines = [FieldLine]()
        lines.reserveCapacity(headers.count)
        for header in headers {
            let requireLiteralRepresentation =
                switch header.indexingStrategy {
                case .prefer, .automatic, .avoid: false
                case .disallow: true
                default: false
                }
            lines.append(
                self.encodeSingleHeader(
                    header,
                    requireLiteralRepresentation: requireLiteralRepresentation
                ).asFieldLine(base: base)
            )
        }
        let prefix = FieldSectionPrefix(requiredInsertCount: 0, base: base)
        let encodedPrefix = prefix.encode(maxCapacity: 0)

        return .init(prefix: encodedPrefix, lines: lines)
    }

    /// - Parameters
    ///     - header: The header to be encoded.
    ///     - requireLiteralRepresentation: If true, a flag will be set requiring intermediates to keep this header as a literal.
    /// - Returns: The encoded header.
    fileprivate func encodeSingleHeader(
        _ header: HTTPField,
        requireLiteralRepresentation: Bool
    ) -> HeaderRepresentation {
        let staticTableEntry = StaticHeaderTable.find(name: header.name, value: header.value)
        if let staticTableEntry, staticTableEntry.containsValue {
            // Exact match in static table
            return .staticTableReference(index: staticTableEntry.index)
        } else if let staticTableEntry {
            // Partial match in static table
            return .staticTableNameReference(
                requireLiteralRepresentation: requireLiteralRepresentation,
                index: staticTableEntry.index,
                value: header.value
            )
        } else {
            // We already checked static table, and there's no dynamic table, so it's a literal
            return .literal(
                requireLiteralRepresentation: requireLiteralRepresentation,
                name: header.name,
                value: header.value
            )
        }
    }
}
