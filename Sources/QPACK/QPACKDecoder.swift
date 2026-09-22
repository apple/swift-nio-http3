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

@_spi(PackageInternal)
public enum QPACKDecoderError: Error, Sendable, Hashable {
    case invalidHeaderName
    case invalidReference
    case invalidFieldSection
}

/// Decodes field sections which reference the QPACK static table only.
///
/// This endpoint advertises a `SETTINGS_QPACK_MAX_TABLE_CAPACITY` of zero, so a conformant peer can neither
/// insert into the dynamic table nor reference it. Any field section which does either is rejected with
/// ``QPACKDecoderError/invalidReference`` or ``QPACKDecoderError/invalidFieldSection``.
@_spi(PackageInternal)
public struct QPACKDecoder: Sendable {
    @_spi(PackageInternal)
    public init() {}

    /// Decode a field section into its HTTP fields.
    @_spi(PackageInternal)
    public func decodeFieldSection(_ fieldSection: FieldSection) throws(QPACKDecoderError) -> [HTTPField] {
        // RFC 9204 § 4.5.1: with an empty dynamic table the only prefix a conformant encoder can produce is a
        // zero Required Insert Count with a non-negative Base.
        guard fieldSection.prefix.encodedRequiredInsertCount == 0, !fieldSection.prefix.signBit else {
            throw QPACKDecoderError.invalidFieldSection
        }
        var fields = [HTTPField]()
        fields.reserveCapacity(fieldSection.lines.count)
        for line in fieldSection.lines {
            try fields.append(self.decodeLine(line))
        }
        return fields
    }

    private func decodeLine(_ line: FieldLine) throws(QPACKDecoderError) -> HTTPField {
        switch line {
        case .indexed(.staticTable, let index):
            guard let entry = StaticHeaderTable.get(at: index) else {
                throw QPACKDecoderError.invalidReference
            }
            return .init(name: entry.0, value: entry.1)
        case .literal(_, let name, let value):
            guard let fieldName = HTTPField.Name(parsed: name) else {
                throw QPACKDecoderError.invalidHeaderName
            }
            return .init(name: fieldName, value: value)
        case .literalWithNameReference(_, .staticTable, let index, let value):
            guard let entry = StaticHeaderTable.get(at: index) else {
                throw QPACKDecoderError.invalidReference
            }
            return .init(name: entry.0, value: value)
        case .indexed(.dynamicTable, _),
            .literalWithNameReference(_, .dynamicTable, _, _),
            .indexedWithPostBase,
            .literalWithNameReferenceWithPostBase:
            // The dynamic table is always empty, so any reference to it is out of range.
            throw QPACKDecoderError.invalidReference
        }
    }
}
