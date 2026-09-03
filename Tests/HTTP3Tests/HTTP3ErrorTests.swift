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

@_spi(PackageInternal) import HTTP3
import HTTPTypes
import Testing

struct HTTP3ErrorTests {
    @Test
    func testHTTP3ErrorCustomStringConvertible() throws {
        var error = HTTP3Error(
            code: .malformedMessage,
            message: "An error message.",
            cause: nil,
            errorCode: nil,
            location: .init(function: "fn(_:)", file: "file.swift", line: 42)
        )

        #expect(String(describing: error) == "malformedMessage: An error message.")

        struct TestError: Error {}
        error.cause = TestError()

        #expect(
            String(describing: error) == "malformedMessage: An error message. (TestError())"
        )
    }

    @Test
    func testHTTP3ErrorCustomDebugStringConvertible() throws {
        var error = HTTP3Error(
            code: .malformedMessage,
            message: "An error message.",
            cause: nil,
            errorCode: nil,
            location: .init(function: "fn(_:)", file: "file.swift", line: 42)
        )

        #expect(
            String(reflecting: error) == """
                malformedMessage: "An error message."
                """
        )

        struct TestError: Error, CustomStringConvertible, CustomDebugStringConvertible {
            var description: String { "TestError()" }
            var debugDescription: String {
                String(reflecting: self.description)
            }
        }
        error.cause = TestError()

        #expect(
            String(reflecting: error) == """
                malformedMessage: "An error message." ("TestError()")
                """
        )
    }

    @Test
    func testHTTP3ErrorDetailedDescription() throws {
        var error = HTTP3Error(
            code: .malformedMessage,
            message: "An error message.",
            cause: nil,
            errorCode: nil,
            location: .init(function: "fn(_:)", file: "file.swift", line: 42)
        )

        #expect(
            error.detailedDescription() == """
                HTTP3Error: malformedMessage
                ├─ Reason: An error message.
                └─ Source location: fn(_:) (file.swift:42)
                """
        )

        struct TestError: Error, CustomStringConvertible {
            var description: String { "TestError()" }
        }
        error.cause = TestError()

        #expect(
            error.detailedDescription() == """
                HTTP3Error: malformedMessage
                ├─ Reason: An error message.
                ├─ Cause: TestError()
                └─ Source location: fn(_:) (file.swift:42)
                """
        )
    }

    @Test
    func testHTTP3ErrorCustomDebugStringConvertibleWithNestedCause() throws {
        let location = HTTP3Error.SourceLocation(
            function: "fn(_:)",
            file: "file.swift",
            line: 42
        )

        let subCause = HTTP3Error(
            code: .invalidGoawayStreamID,
            message: "bad id",
            cause: nil,
            errorCode: nil,
            location: location
        )

        let cause = HTTP3Error(
            code: .invalidFramePayload,
            message: "Bad frame",
            cause: subCause,
            errorCode: nil,
            location: location
        )

        let error = HTTP3Error(
            code: .malformedMessage,
            message: "Formation is bad",
            cause: cause,
            errorCode: nil,
            location: location
        )

        #expect(
            error.detailedDescription() == """
                HTTP3Error: malformedMessage
                ├─ Reason: Formation is bad
                ├─ Cause:
                │  └─ HTTP3Error: invalidFramePayload
                │     ├─ Reason: Bad frame
                │     ├─ Cause:
                │     │  └─ HTTP3Error: invalidGoawayStreamID
                │     │     ├─ Reason: bad id
                │     │     └─ Source location: fn(_:) (file.swift:42)
                │     └─ Source location: fn(_:) (file.swift:42)
                └─ Source location: fn(_:) (file.swift:42)
                """
        )
    }

    @Test
    func testSourceLocationDescription() {
        let location = HTTP3Error.SourceLocation(function: "fn(_:)", file: "file.swift", line: 42)
        #expect("\(location)" == "fn(_:) (file.swift:42)")
    }
}
