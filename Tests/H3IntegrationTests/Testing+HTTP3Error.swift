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

import HTTP3
import HTTPTypes
import Testing

func expectH3Error(
    code: HTTP3Error.Code,
    h3ErrorCode: HTTP3ErrorCode,
    message: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    block: () throws -> Void
) {
    #expect(
        sourceLocation: sourceLocation,
        performing: block,
        throws: { error in
            let h3Error = error as? HTTP3Error
            return h3Error?.code == code && h3Error?.h3ErrorCode == h3ErrorCode
                && (h3Error?.message == message || message == nil)
        }
    )
}

func expectH3ErrorEqual(
    error: (any Error)?,
    expectedCode: HTTP3Error.Code,
    expectedH3ErrorCode: HTTP3ErrorCode?,
    expectedMessage: String? = nil,
    verifyCause: (((any Error)?) -> Void)? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let h3Error = error as? HTTP3Error else {
        Issue.record(
            "Expected HTTP3Error, got \(error.map(String.init(describing:)) ?? "nil")",
            sourceLocation: sourceLocation
        )
        return
    }
    #expect(h3Error.code == expectedCode, sourceLocation: sourceLocation)
    #expect(h3Error.h3ErrorCode == expectedH3ErrorCode, sourceLocation: sourceLocation)
    if let expectedMessage {
        #expect(h3Error.message == expectedMessage, sourceLocation: sourceLocation)
    }
    verifyCause?(h3Error.cause)
}
