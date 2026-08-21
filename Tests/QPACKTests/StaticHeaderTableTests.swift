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

import NIOCore
@testable import QPACK
import Testing

struct StaticHeaderTableTests {
    @Test
    func testIndex() throws {
        // RFC 9204 Appendix A. Static Table
        #expect(StaticHeaderTable.get(at: 0)?.0.rawName == ":authority")
        #expect(StaticHeaderTable.get(at: 0)?.1 == "")

        #expect(StaticHeaderTable.get(at: 0)?.0.rawName == ":authority")
        #expect(StaticHeaderTable.get(at: 0)?.1 == "")

        #expect(StaticHeaderTable.get(at: 98)?.0.rawName == "x-frame-options")
        #expect(StaticHeaderTable.get(at: 98)?.1 == "sameorigin")

        #expect(StaticHeaderTable.get(at: 10000) == nil)
    }
}
