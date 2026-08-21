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

/// Decides when to send a section acknowledgment (RFC 9204 § 4.4.1).
/// This allows us to conform to RFC 9204 § 2.2.2.
struct QPACKStateSynchronizer {
    private var lastCountAcknowledged: Int = 0

    init() {}

    /// Called when a field section has been processed.
    /// - Parameter insertCount: The required insert count of the processed section as per RFC 9204 § 4.5.1.
    mutating func sectionProcessed(withRequiredInsertCount insertCount: Int) {
        if self.lastCountAcknowledged < insertCount {
            self.lastCountAcknowledged = insertCount
        }
    }

    /// Called when a new header has been added to the dynamic table of the decoder.
    /// - Parameter insertCount: The total number of dynamic-table inserts that have been performed so far.
    /// - Returns: true if an `insert count increment decoder instruction` (RFC 9204 § 4.4.3) should be sent.
    mutating func dynamicTableEntryAdded(insertCount: Int) -> Bool {
        if self.lastCountAcknowledged < insertCount {
            self.lastCountAcknowledged = insertCount
            return true
        }
        return false
    }
}
