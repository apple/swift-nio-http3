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

/// The result of encoding a single line. Contains the encoded form of the line + the instruction needed, if any.
@available(anyAppleOS 27, *)
private struct QPACKEncodeSingleResult {
    let headerRepresentation: HeaderRepresentation
    let instruction: QPACKEncoderInstruction?

    init(headerRepresentation: HeaderRepresentation, instruction: QPACKEncoderInstruction?) {
        self.headerRepresentation = headerRepresentation
        self.instruction = instruction
    }
}

/// A full QPACK encoder which may use the dynamic table and may emit instructions.
@available(anyAppleOS 27, *)
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
        var section = SectionState(base: self.table.insertCount, fieldCount: headers.count)
        var lines = [FieldLine]()
        lines.reserveCapacity(headers.count)
        for header in headers {
            lines.append(self.fieldLine(for: header, forStream: streamID, section: &section))
        }
        let prefix = self.finishSection(section, forStream: streamID)
        return .init(fieldSection: .init(prefix: prefix, lines: lines), instructions: section.instructions)
    }

    /// The largest number of bytes ``encode(headers:forStream:into:preferHuffmanEncoding:)`` appends for `headers`,
    /// if it is called next.
    @_spi(PackageInternal)
    public func maxEncodedLength(of headers: [HTTPField]) -> Int {
        // A dynamic table entry takes 32 bytes at the least, so its relative index is below this.
        let maxEntries = self.table.maximumCapacity / 32
        return self.maxPrefixLength(fieldCount: headers.count)
            &+ QPACKEncodedLength.maxFieldLines(headers, indexLimit: max(StaticHeaderTable.raw.count, maxEntries))
    }

    /// Encodes `headers` into a field section, and appends it to `output`. No intermediate ``FieldSection`` is built.
    ///
    /// - Precondition: `output` has room for ``maxEncodedLength(of:)`` more bytes.
    /// - Returns: The instructions the peer's decoder needs to decode the field section. They must be sent on the
    ///   encoder stream.
    @_spi(PackageInternal)
    public mutating func encode(
        headers: [HTTPField],
        forStream streamID: QUICStreamID,
        into output: inout OutputRawSpan,
        preferHuffmanEncoding: Bool
    ) -> [QPACKEncoderInstruction] {
        var section = SectionState(base: self.table.insertCount, fieldCount: headers.count)
        // The prefix comes first, but depends on the dynamic table entries the field lines reference. Leave room for
        // the longest one it can be, and fill it in once the lines are written.
        output.appendFieldSection(maxPrefixLength: self.maxPrefixLength(fieldCount: headers.count)) { lines in
            for header in headers {
                lines.appendFieldLine(
                    self.fieldLine(for: header, forStream: streamID, section: &section),
                    preferHuffmanEncoding: preferHuffmanEncoding
                )
            }
            return self.finishSection(section, forStream: streamID)
        }
        return section.instructions
    }

    /// The longest prefix of a field section with `fieldCount` fields, if it is encoded next.
    private func maxPrefixLength(fieldCount: Int) -> Int {
        // The Required Insert Count can't exceed the insert count after this section, which inserts one entry per
        // field at most. RFC 9204 § 4.5.1.1: it is either 0 or encoded as (ReqInsertCount mod (2 * MaxEntries)) + 1,
        // which is at most 2 * MaxEntries, and at most ReqInsertCount + 1.
        let maxEntries = self.table.maximumCapacity / 32
        let maxRequiredInsertCount = self.table.insertCount &+ fieldCount
        // RFC 9204 § 4.5.1.2: Base is the current insert count. The Delta Base is either Base - ReqInsertCount, which
        // is at most Base, or ReqInsertCount - Base - 1, which is less than the number of entries this section inserts.
        return QPACKEncodedLength.prefixedInteger(min(2 &* maxEntries, maxRequiredInsertCount &+ 1), prefix: 8)
            &+ QPACKEncodedLength.prefixedInteger(max(self.table.insertCount, fieldCount), prefix: 7)
    }

    /// What the encoder needs to remember while it encodes the fields of a section.
    private struct SectionState {
        /// The Base of the section: the insert count when it was started.
        let base: Int
        /// The highest absolute index of the dynamic table entries the section references.
        var highestRequiredIndex: Int? = nil
        /// The absolute indices of the dynamic table entries the section references.
        var requiredIndices = [Int]()
        /// The instructions the peer's decoder needs to decode the section.
        var instructions = [QPACKEncoderInstruction]()

        init(base: Int, fieldCount: Int) {
            self.base = base
            // At most, each header can require one instruction
            self.instructions.reserveCapacity(fieldCount)
        }
    }

    /// Encodes a single field of the section described by `section`.
    private mutating func fieldLine(
        for header: HTTPField,
        forStream streamID: QUICStreamID,
        section: inout SectionState
    ) -> FieldLine {
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
            section.instructions.append(ins)
        }
        if let requiredIndex = encoded.requiredIndex {
            section.requiredIndices.append(requiredIndex)
            if let existing = section.highestRequiredIndex {
                section.highestRequiredIndex = max(existing, requiredIndex)
            } else {
                section.highestRequiredIndex = requiredIndex
            }
        }
        return encoded.asFieldLine(base: section.base)
    }

    /// Records the dynamic table entries the section references, and returns its prefix.
    private mutating func finishSection(
        _ section: SectionState,
        forStream streamID: QUICStreamID
    ) -> EncodedFieldSectionPrefix {
        // insert count is one more than absolute index
        let requiredInsertCount = section.highestRequiredIndex.map { $0 + 1 } ?? 0
        if !section.requiredIndices.isEmpty {
            self.streamTracker.recordSentMessage(
                StreamTrackerMessage(
                    dynamicTableIndices: section.requiredIndices,
                    requiredInsertCount: requiredInsertCount
                ),
                forStream: streamID
            )
        }
        let prefix = FieldSectionPrefix(requiredInsertCount: requiredInsertCount, base: section.base)
        return prefix.encode(maxCapacity: self.table.maximumCapacity)
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
