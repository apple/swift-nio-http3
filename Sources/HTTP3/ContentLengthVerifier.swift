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

import HTTPTypes

@available(anyAppleOS 27, *)
struct ContentLengthVerifier {
    private let remainingBytes: Int?

    private init(remainingBytes: Int?) {
        self.remainingBytes = remainingBytes
    }

    static func verifyingRequest(_ headers: HTTP3Frame.Headers, requestMethod: HTTPRequest.Method) -> Verdict {
        switch requestMethod {
        case .connect:
            .valid(Self(remainingBytes: nil))
        default:
            Self.parsingContentLength(headers)
        }
    }

    static func verifyingResponse(_ headers: HTTP3Frame.Headers, requestMethod: HTTPRequest.Method) -> Verdict {
        let status = headers.fields.first(where: { $0.name == .status }).flatMap { Int($0.value) }
        switch (requestMethod, status) {
        case (.connect, .some(200..<300)):
            return .valid(Self(remainingBytes: nil))
        case (.head, _), (_, .some(204)), (_, .some(304)):
            return .valid(Self(remainingBytes: 0))
        default:
            return Self.parsingContentLength(headers)
        }
    }

    func receivedData(length: Int) -> Verdict {
        guard let remainingBytes = self.remainingBytes else {
            return .valid(self)
        }
        guard length <= remainingBytes else {
            return .malformed(.dataExceedsContentLength)
        }
        return .valid(Self(remainingBytes: remainingBytes - length))
    }

    func endOfMessage() -> Verdict {
        switch self.remainingBytes {
        case .none, .some(0):
            .valid(self)
        case .some:
            .malformed(.dataShorterThanContentLength)
        }
    }

    private static func parsingContentLength(_ headers: HTTP3Frame.Headers) -> Verdict {
        var value: String?
        for field in headers.fields where field.name == .contentLength {
            guard value == nil || value == field.value else {
                return .malformed(.conflictingValues)
            }
            value = field.value
        }
        guard let value else {
            return .valid(Self(remainingBytes: nil))
        }
        guard value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
            let length = Int(value)
        else {
            return .malformed(.invalidValue)
        }
        return .valid(Self(remainingBytes: length))
    }
}

@available(anyAppleOS 27, *)
extension ContentLengthVerifier {
    enum Error: Swift.Error, Sendable, Hashable, CustomStringConvertible {
        case conflictingValues
        case invalidValue
        case dataExceedsContentLength
        case dataShorterThanContentLength

        var description: String {
            switch self {
            case .conflictingValues:
                "Conflicting content-length values"
            case .invalidValue:
                "Invalid content-length value"
            case .dataExceedsContentLength:
                "DATA exceeds the content-length"
            case .dataShorterThanContentLength:
                "DATA is shorter than the content-length"
            }
        }
    }

    enum Verdict {
        case valid(ContentLengthVerifier)
        case malformed(Error)
    }
}
