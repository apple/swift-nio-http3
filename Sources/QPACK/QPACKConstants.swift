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
    /// Default capacity for field lines array when reading field sections.
    /// Used for performance optimization to reduce array reallocations.
    static var defaultFieldLinesCapacity: Int { 16 }
}
