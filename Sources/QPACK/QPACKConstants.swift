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

@_spi(PackageInternal)
public enum QPACKConstants {
    /// Rough estimate of bytes per header for initial capacity calculation.
    /// Used in HeaderTableStorage initialization for performance optimization.
    static var estimatedBytesPerHeader: Int { 64 }

    /// Default target evictable fraction for dynamic header table.
    /// This fraction of the table is kept evictable to reduce blocking.
    /// Value should be between 0.0 and 1.0 (exclusive).
    @_spi(PackageInternal)
    @inlinable
    public static var defaultTargetEvictableFraction: Double { 0.1 }

    /// Default capacity for field lines array when reading field sections.
    /// Used for performance optimization to reduce array reallocations.
    static var defaultFieldLinesCapacity: Int { 16 }

    /// Maximum compression efficiency heuristic for Huffman decoding.
    /// Used to estimate buffer capacity needed for decoded strings.
    static var huffmanMaxCompressionRatio: Int { 2 }
}
