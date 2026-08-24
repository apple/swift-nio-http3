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

import Testing

@testable import HTTP3

struct HTTP3GoawayIDTests {
    @Test
    func goawayComparable() {
        #expect(HTTP3GoawayID(rawValue: 0) < HTTP3GoawayID(rawValue: 1))
        #expect(HTTP3GoawayID(rawValue: 1) < HTTP3GoawayID(rawValue: 2))
        #expect(HTTP3GoawayID(rawValue: (2 << 61) - 2) < HTTP3GoawayID(rawValue: (2 << 61) - 1))
    }
}
