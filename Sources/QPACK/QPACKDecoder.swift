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

@_spi(PackageInternal)
public enum QPACKDecoderError: Error, Sendable, Hashable {
    case invalidHeaderName
    case invalidReference
    case invalidFieldSection
}

/// The result of decoding a field section, plus the instruction which need to be sent back, if any.
@_spi(PackageInternal)
public enum QPACKFullDecodeResult: Sendable {
    /// The section cannot not be decoded because we don't have the required insert count. You can try again later.
    case missingInsertCount
    /// The section has been decoded with the given result. Also, an instruction may need to be sent to the remote.
    case success([HTTPField], QPACKDecoderInstruction?)
    /// The section failed to decode.
    case error(QPACKDecoderError)
}

/// The result of decoding a field section.
enum QPACKDecodeResult: Sendable {
    /// The section cannot not be decoded because we don't have the required insert count. You can try again later.
    case missingInsertCount
    /// The section has been decoded with the given result.
    case success([HTTPField])
    /// The section failed to decode.
    case error(any Error)
}

@_spi(PackageInternal)
public struct QPACKDecoder {
    private var dynamicTable: DynamicHeaderTable
    /// Makes decisions on when and how to sync state with the encoder.
    private var stateSynchronizer: QPACKStateSynchronizer
    /// The number of dynamic table inserts we have acknowledged. See RFC 9204 § 2.1.4.
    private var knownReceivedCount = 0

    package var insertCount: Int {
        self.dynamicTable.insertCount
    }

    /// - Parameter dynamicTableMaxCapacity: The max the encoder can set the dynamic table capacity to (RFC 9204 § 3.2.3).
    @_spi(PackageInternal)
    public init(dynamicTableMaxCapacity: Int) {
        self.stateSynchronizer = QPACKStateSynchronizer()
        // RFC 9204 § 3.2.2 The initial capacity of the dynamic table is zero
        // Target evictable is irrelevant to the decoder
        self.dynamicTable = DynamicHeaderTable(
            maximumCapacity: dynamicTableMaxCapacity,
            initialCapacity: 0,
            targetEvictableFraction: 0.0,
            assumeAllEntriesReceived: true
        )
    }

    /// Process an encoder instruction and (maybe) emit a decoder instruction to send back.
    @_spi(PackageInternal)
    public mutating func processInstruction(
        _ instruction: QPACKEncoderInstruction
    ) throws -> QPACKDecoderInstruction? {
        switch instruction {
        case .setDynamicTableCapacity(let capacity):
            try self.dynamicTable.setCurrentCapacity(capacity)
            return nil
        case .insertWithLiteralName(let name, let value):
            guard let fieldName = HTTPField.Name(parsed: name) else {
                throw QPACKDecoderError.invalidHeaderName
            }
            return try self.addDynamicTableEntry(named: fieldName, value: value)
        case .insertWithNameReference(let table, let relativeIndex, let value):
            let name: HTTPField.Name
            switch table {
            case .staticTable:
                guard let staticTableEntry = StaticHeaderTable.get(at: relativeIndex) else {
                    throw QPACKDecoderError.invalidReference
                }
                name = staticTableEntry.0
            case .dynamicTable:
                guard let entry = self.dynamicTable.get(relativeIndex: relativeIndex) else {
                    throw QPACKDecoderError.invalidReference
                }
                name = entry.name
            }
            return try self.addDynamicTableEntry(named: name, value: value)
        case .duplicateEntry(let relativeIndex):
            guard let original = self.dynamicTable.get(relativeIndex: relativeIndex) else {
                throw QPACKDecoderError.invalidReference
            }
            return try self.addDynamicTableEntry(named: original.name, value: original.value)
        }
    }

    /// Add an entry to the dynamic table and (maybe) return an insertCountIncrement.
    private mutating func addDynamicTableEntry(
        named name: HTTPField.Name,
        value: String
    ) throws -> QPACKDecoderInstruction? {
        try self.dynamicTable.addHeader(named: name, value: value)
        let insertCount = self.dynamicTable.insertCount
        let shouldAck = self.stateSynchronizer.dynamicTableEntryAdded(insertCount: insertCount)
        if shouldAck {
            let increment = insertCount - self.knownReceivedCount
            assert(
                increment > 0,
                "insertCount (\(insertCount)) must be more than knownReceivedCount \(self.knownReceivedCount)"
            )
            self.knownReceivedCount = insertCount
            return .insertCountIncrement(increment: increment)
        }
        return nil
    }

    @_spi(PackageInternal)
    public func cancelStream(streamID: QUICStreamID) -> QPACKDecoderInstruction? {
        if self.dynamicTable.maximumCapacity == 0 {
            // A decoder with a maximum dynamic table capacity equal to zero MAY omit sending Stream
            // Cancellations, because the encoder cannot have any dynamic table references.
            return nil
        } else {
            return .streamCancellation(streamID: streamID)
        }
    }

    /// Return a list of headers for a FieldSection, if the required insert count is met.
    /// Otherwise, return ``QPACKDecodeResult/missingInsertCount``.
    @_spi(PackageInternal)
    public mutating func decodeFieldSection(
        prefix: FieldSectionPrefix,
        lines: [FieldLine],
        streamID: QUICStreamID
    ) -> QPACKFullDecodeResult {
        guard prefix.requiredInsertCount <= self.dynamicTable.insertCount else {
            return .missingInsertCount
        }
        do {
            var fields = [HTTPField]()
            fields.reserveCapacity(lines.count)
            for line in lines {
                try fields.append(self.decodeLine(line, prefix: prefix))
            }
            self.stateSynchronizer.sectionProcessed(withRequiredInsertCount: prefix.requiredInsertCount)
            // 4.4.1 After processing an encoded field section whose declared Required Insert Count is not zero, the decoder emits a Section Acknowledgment instruction
            if prefix.requiredInsertCount > 0 {
                return .success(fields, .sectionAcknowledgement(streamID: streamID))
            } else {
                return .success(fields, nil)
            }
        } catch {
            return .error(error)
        }
    }

    private func decodeLine(_ line: FieldLine, prefix: FieldSectionPrefix) throws(QPACKDecoderError) -> HTTPField {
        switch line {
        case .indexed(let table, let index):
            let name: HTTPField.Name
            let value: String
            switch table {
            case .staticTable:
                guard let entry = StaticHeaderTable.get(at: index) else {
                    throw QPACKDecoderError.invalidReference
                }
                name = entry.0
                value = entry.1
            case .dynamicTable:
                // In a field line representation, a relative index of 0 refers to the entry with absolute index equal to Base - 1
                let absoluteIndex = prefix.base - 1 - index
                guard let entry = self.dynamicTable.get(absoluteIndex: absoluteIndex) else {
                    throw QPACKDecoderError.invalidReference
                }
                name = entry.name
                value = entry.value
            }
            return .init(name: name, value: value)
        case .literal(_, let name, let value):
            guard let fieldName = HTTPField.Name(parsed: name) else {
                throw QPACKDecoderError.invalidHeaderName
            }
            return .init(name: fieldName, value: value)
        case .literalWithNameReference(_, let table, let index, let value):
            let name: HTTPField.Name
            switch table {
            case .staticTable:
                guard let entry = StaticHeaderTable.get(at: index) else {
                    throw QPACKDecoderError.invalidReference
                }
                name = entry.0
            case .dynamicTable:
                // In a field line representation, a relative index of 0 refers to the entry with absolute index equal to Base - 1
                let absoluteIndex = prefix.base - 1 - index
                guard let entry = self.dynamicTable.get(absoluteIndex: absoluteIndex) else {
                    throw QPACKDecoderError.invalidReference
                }
                name = entry.name
            }
            return .init(name: name, value: value)
        case .indexedWithPostBase(let index):
            // Post-Base indices are used in field line representations for entries with absolute indices greater
            // than or equal to Base, starting at 0 for the entry with absolute index equal to Base and increasing
            // in the same direction as the absolute index.
            let absoluteIndex = prefix.base + index
            guard let entry = self.dynamicTable.get(absoluteIndex: absoluteIndex) else {
                throw QPACKDecoderError.invalidReference
            }
            return .init(name: entry.name, value: entry.value)
        case .literalWithNameReferenceWithPostBase(_, let index, let value):
            let absoluteIndex = prefix.base + index
            guard let entry = self.dynamicTable.get(absoluteIndex: absoluteIndex) else {
                throw QPACKDecoderError.invalidReference
            }
            return .init(name: entry.name, value: value)
        }
    }

    package func decodeFieldSectionPrefix(_ prefix: EncodedFieldSectionPrefix) -> FieldSectionPrefix? {
        prefix.decode(totalInserts: self.insertCount, maxCapacity: self.dynamicTable.maximumCapacity)
    }
}
