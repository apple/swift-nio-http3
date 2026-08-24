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

public import NIOQUICHelpers

@_spi(PackageInternal)
public enum QPACKReferenceTable: Sendable, Hashable {
    case staticTable
    case dynamicTable

    /// QPACK often uses the `1` bit to refer to the static table and `0` to refer to dynamic.
    /// This function makes it easier to parse such bits.
    /// - Parameter b: The bool to check.
    /// - Returns: The static table if true, otherwise dynamic.
    static func staticIfTrue(_ b: Bool) -> Self {
        b ? .staticTable : .dynamicTable
    }
}

/// Encoder instructions from RFC 9204 § 4.3.
@_spi(PackageInternal)
public enum QPACKEncoderInstruction: Sendable, Hashable {
    /// 4.3.1. Set Dynamic Table Capacity.
    case setDynamicTableCapacity(Int)
    /// 4.3.2. Insert with Name Reference.
    case insertWithNameReference(QPACKReferenceTable, relativeIndex: Int, value: String)
    /// 4.3.3. Insert with Literal Name.
    case insertWithLiteralName(name: String, value: String)
    /// 4.3.4. Duplicate.
    case duplicateEntry(relativeIndex: Int)
}

/// Decoder instructions from RFC 9204 § 4.4.
@_spi(PackageInternal)
public enum QPACKDecoderInstruction: Sendable, Hashable {
    /// 4.4.1. Section Acknowledgment.
    case sectionAcknowledgement(streamID: QUICStreamID)
    /// 4.4.2. Stream Cancellation.
    case streamCancellation(streamID: QUICStreamID)
    /// 4.4.3. Insert Count Increment.
    case insertCountIncrement(increment: Int)
}
