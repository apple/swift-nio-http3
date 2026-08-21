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

struct Decoded<Value: Sendable & Hashable>: Sendable, Hashable {
    var value: Value
    var bytesRead: Int
}

@_spi(PackageInternal)
public enum IntegerReadingError: Error, Hashable {
    /// The integer cannot be represented in the desired type.
    case unrepresentable
}
