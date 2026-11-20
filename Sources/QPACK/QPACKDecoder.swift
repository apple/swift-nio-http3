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
import NIOQUICHelpers

import struct NIOCore.ByteBuffer

/// Why a field section could not be decoded.
///
/// The cases fall into two groups, which call for different handling.
///
/// - ``invalidHeaderName`` and ``invalidHeaderValue``: the field section decoded fine, but the message it carries
///   is malformed (RFC 9114 § 4.1.2). Only the stream the section arrived on is at fault: reset it with
///   H3_MESSAGE_ERROR, and keep the connection open.
/// - ``invalidReference`` and ``invalidFieldSection``: the peer's encoder produced something malformed.
///   That is a connection error of type QPACK_DECOMPRESSION_FAILED (RFC 9204 § 6).
@available(anyAppleOS 27, *)
@nonexhaustive
public enum QPACKDecoderError: Error, Sendable, Hashable {
    /// Whether the failure, raised while decoding a field section on a request stream, is fatal to the connection,
    /// as a QPACK_DECOMPRESSION_FAILED error, rather than only to the stream whose field section it is.
    ///
    /// This doesn't apply to an encoder instruction the decoder can't apply: that is always a connection error,
    /// whichever case it is, and reported as ``QPACKError/invalidEncoderInstruction``.
    var isConnectionErrorInRequestStream: Bool {
        switch self {
        case .invalidHeaderName, .invalidHeaderValue:
            return false
        case .invalidReference, .invalidFieldSection:
            // RFC 9204 § 2.2.3: a reference to a dynamic table entry that has already been evicted or that has an
            // absolute index greater than or equal to the declared Required Insert Count MUST be treated as a
            // connection error of type QPACK_DECOMPRESSION_FAILED. RFC 9204 § 6 says the same of anything else
            // which can't be decoded.
            return true
        }
    }

    /// A field name is not valid in HTTP/3, for example because it holds upper case characters (RFC 9114 § 4.2).
    case invalidHeaderName

    /// A field value holds a character which isn't permitted: a control character other than HTAB, such as
    /// CR, LF or NUL, or DEL (RFC 9114 § 10.3, RFC 9110 § 5.5).
    case invalidHeaderValue

    /// A field line references a table entry which doesn't exist (RFC 9204 § 2.2.3).
    case invalidReference

    /// The field section's prefix or one of its field lines can't be decoded: it ends early, holds an integer too
    /// large to represent, a malformed Huffman string, or a prefix which needs a dynamic table the decoder doesn't
    /// have (RFC 9204 § 4.5).
    case invalidFieldSection
}

/// The result of decoding a field section, plus the instruction which need to be sent back, if any.
@available(anyAppleOS 27, *)
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

@available(anyAppleOS 27, *)
struct QPACKDecoder {
    private var dynamicTable: DynamicHeaderTable
    /// Makes decisions on when and how to sync state with the encoder.
    private var stateSynchronizer: QPACKStateSynchronizer
    /// The number of dynamic table inserts we have acknowledged. See RFC 9204 § 2.1.4.
    private var knownReceivedCount = 0

    var insertCount: Int {
        self.dynamicTable.insertCount
    }

    /// - Parameter dynamicTableMaxCapacity: The max the encoder can set the dynamic table capacity to (RFC 9204 § 3.2.3).
    init(dynamicTableMaxCapacity: Int) {
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
    mutating func processInstruction(
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
            return try self.addDynamicTableEntry(validatedName: fieldName, unvalidatedValue: value)
        case .insertWithNameReference(let table, let relativeIndex, let value):
            let name: HTTPField.Name
            switch table {
            case .staticTable:
                guard let staticTableEntry = StaticHeaderTable.get(at: relativeIndex) else {
                    throw QPACKDecoderError.invalidReference
                }
                name = staticTableEntry.name
            case .dynamicTable:
                guard let entry = self.dynamicTable.get(relativeIndex: relativeIndex) else {
                    throw QPACKDecoderError.invalidReference
                }
                name = entry.name
            }
            return try self.addDynamicTableEntry(validatedName: name, unvalidatedValue: value)
        case .duplicateEntry(let relativeIndex):
            guard let original = self.dynamicTable.get(relativeIndex: relativeIndex) else {
                throw QPACKDecoderError.invalidReference
            }
            // The value was checked when the original was inserted.
            return try self.insertDynamicTableEntry(validatedName: original.name, validatedValue: original.value)
        }
    }

    /// Add an entry to the dynamic table and (maybe) return an insertCountIncrement.
    private mutating func addDynamicTableEntry(
        validatedName name: HTTPField.Name,
        unvalidatedValue: String
    ) throws -> QPACKDecoderInstruction? {
        // The table keeps an `HTTPField`, which would replace characters which aren't permitted with spaces. This is
        // the only place which sees the value as it was sent, so it has to be checked here, not by `decodeLine`.
        //
        // In a field section, `invalidHeaderValue` is only a stream error (see `isConnectionErrorInRequestStream`):
        // just that one message is malformed. Here it is a connection error: the encoder has already counted the
        // insert, so skipping it would leave the two tables out of sync. The caller reports it as
        // `QPACKError.invalidEncoderInstruction`.
        guard HTTPField.isPermittedValue(unvalidatedValue) else {
            throw QPACKDecoderError.invalidHeaderValue
        }
        return try self.insertDynamicTableEntry(validatedName: name, validatedValue: unvalidatedValue)
    }

    /// Add an entry whose value is known to be permitted to the dynamic table and (maybe) return an
    /// insertCountIncrement.
    private mutating func insertDynamicTableEntry(
        validatedName name: HTTPField.Name,
        validatedValue value: String
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

    func cancelStream(streamID: QUICStreamID) -> QPACKDecoderInstruction? {
        if self.dynamicTable.maximumCapacity == 0 {
            // A decoder with a maximum dynamic table capacity equal to zero MAY omit sending Stream
            // Cancellations, because the encoder cannot have any dynamic table references.
            return nil
        } else {
            return .streamCancellation(streamID: streamID)
        }
    }

    /// Return a list of headers for a field section, if the required insert count is met.
    /// Otherwise, return ``QPACKDecodeResult/missingInsertCount``.
    ///
    /// `lines` are the encoded field lines which follow the field section's prefix. They are read one at a time, so
    /// that no list of them is ever built.
    mutating func decodeFieldSection(
        prefix: FieldSectionPrefix,
        lines: ByteBuffer,
        streamID: QUICStreamID
    ) -> QPACKFullDecodeResult {
        guard prefix.requiredInsertCount <= self.dynamicTable.insertCount else {
            return .missingInsertCount
        }
        var lines = lines
        do {
            var fields = [HTTPField]()
            fields.reserveCapacity(QPACKConstants.defaultFieldLinesCapacity)
            while lines.readableBytes > 0 {
                // A line which ends early, or holds an integer too large to represent, can't be decoded. RFC 9204 § 6
                // makes that a connection error of type QPACK_DECOMPRESSION_FAILED.
                guard let line = try? lines.readFieldLine() else {
                    return .error(.invalidFieldSection)
                }
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
                name = entry.name
                value = entry.value
            case .dynamicTable:
                // In a field line representation, a relative index of 0 refers to the entry with absolute index equal to Base - 1
                // `index` comes from the wire and can be larger than Base, which yields a negative absolute index.
                let absoluteIndex = prefix.base - 1 - index
                let entry = try self.dynamicTableEntry(absoluteIndex: absoluteIndex, prefix: prefix)
                name = entry.name
                value = entry.value
            }
            return .init(name: name, value: value)
        case .literal(_, let name, let value):
            guard let fieldName = HTTPField.Name(parsed: name) else {
                throw QPACKDecoderError.invalidHeaderName
            }
            return try HTTPField.makeField(name: fieldName, validatingValue: value)
        case .literalWithNameReference(_, let table, let index, let value):
            let name: HTTPField.Name
            switch table {
            case .staticTable:
                guard let entry = StaticHeaderTable.get(at: index) else {
                    throw QPACKDecoderError.invalidReference
                }
                name = entry.name
            case .dynamicTable:
                // In a field line representation, a relative index of 0 refers to the entry with absolute index equal to Base - 1
                // `index` comes from the wire and can be larger than Base, which yields a negative absolute index.
                let absoluteIndex = prefix.base - 1 - index
                let entry = try self.dynamicTableEntry(absoluteIndex: absoluteIndex, prefix: prefix)
                name = entry.name
            }
            return try HTTPField.makeField(name: name, validatingValue: value)
        case .indexedWithPostBase(let index):
            // Post-Base indices are used in field line representations for entries with absolute indices greater
            // than or equal to Base, starting at 0 for the entry with absolute index equal to Base and increasing
            // in the same direction as the absolute index.
            // With a Required Insert Count of zero, Base is the peer's Delta Base, which can be `Int.max`.
            let (absoluteIndex, overflow) = prefix.base.addingReportingOverflow(index)
            guard !overflow else {
                throw QPACKDecoderError.invalidReference
            }
            let entry = try self.dynamicTableEntry(absoluteIndex: absoluteIndex, prefix: prefix)
            return .init(name: entry.name, value: entry.value)
        case .literalWithNameReferenceWithPostBase(_, let index, let value):
            // With a Required Insert Count of zero, Base is the peer's Delta Base, which can be `Int.max`.
            let (absoluteIndex, overflow) = prefix.base.addingReportingOverflow(index)
            guard !overflow else {
                throw QPACKDecoderError.invalidReference
            }
            let entry = try self.dynamicTableEntry(absoluteIndex: absoluteIndex, prefix: prefix)
            return try HTTPField.makeField(name: entry.name, validatingValue: value)
        }
    }

    /// The dynamic table entry with `absoluteIndex`, if the field section may reference it.
    private func dynamicTableEntry(
        absoluteIndex: Int,
        prefix: FieldSectionPrefix
    ) throws(QPACKDecoderError) -> HeaderTableEntry {
        // RFC 9204 § 2.2.3: a reference to an absolute index greater than or equal to the Required Insert Count is
        // an error, even if the table holds the entry. `DynamicHeaderTable` overflows on a negative absolute index.
        guard absoluteIndex >= 0, absoluteIndex < prefix.requiredInsertCount,
            let entry = self.dynamicTable.get(absoluteIndex: absoluteIndex)
        else {
            throw QPACKDecoderError.invalidReference
        }
        return entry
    }

    func decodeFieldSectionPrefix(_ prefix: EncodedFieldSectionPrefix) -> FieldSectionPrefix? {
        prefix.decode(totalInserts: self.insertCount, maxCapacity: self.dynamicTable.maximumCapacity)
    }
}

extension HTTPField {
    /// A field whose value comes from the wire.
    ///
    /// `HTTPField(name:value:)` on its own would replace characters which aren't permitted with spaces. RFC 9114
    /// § 10.3 requires a message with such a value to be treated as malformed instead, so it is rejected here.
    /// Leading and trailing whitespace is permitted, just not part of the value: `HTTPField` trims it.
    @available(anyAppleOS 27, *)
    static func makeField(name: HTTPField.Name, validatingValue value: String) throws(QPACKDecoderError) -> HTTPField {
        let field = HTTPField(name: name, value: value)
        // `HTTPField` already scans the value, and keeps it as it is if it is valid. Then this compares the string
        // with itself, which takes no time. Only a value `HTTPField` changed needs the second, exact scan: it may
        // just have trimmed whitespace, which is fine.
        if field.value != value && !Self.isPermittedValue(value) {
            throw QPACKDecoderError.invalidHeaderValue
        }
        return field
    }

    /// Whether `value` holds only characters RFC 9110 § 5.5 permits in a field value: visible characters, SP, HTAB
    /// and obs-text. DEL and every control character other than HTAB are not permitted, CR, LF and NUL included.
    ///
    /// Unlike `HTTPField.isValidValue`, this permits leading and trailing whitespace. That isn't part of the value
    /// according to the grammar, but RFC 9114 § 10.3 only makes characters which aren't permitted malformed.
    @available(anyAppleOS 27, *)
    static func isPermittedValue(_ value: String) -> Bool {
        let bytes = value.utf8.span
        // Index loop rather than `for byte in bytes`, which compiles to slower code (Swift 6.4).
        for index in bytes.indices {
            let byte = bytes[index]
            if (byte < 0x20 && byte != 0x09) || byte == 0x7F {
                return false
            }
        }
        return true
    }
}
