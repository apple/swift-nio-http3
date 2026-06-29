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
import NIOCore
import NIOEmbedded
import NIOHTTP3
import NIOHTTPTypes
import Testing

struct HTTPMessageParsingTests {
    let validRequestHead: HTTP3Frame = .headers([
        .init(name: .method, value: "GET"),
        .init(name: .scheme, value: "https"),
        .init(name: .authority, value: "test"),
        .init(name: .path, value: "/"),
    ])

    let validResponseHead: HTTP3Frame = .headers([
        .init(name: .status, value: "200")
    ])

    let validTrailers: HTTP3Frame = .headers([
        .init(name: .init("test")!, value: "hello")
    ])

    @Test(arguments: 0...10)
    func testProcessRequestFramesWithTrailers(numDataFrames: Int) throws {
        var machine = HTTPMessageParsingStateMachine<HTTPRequestPart>()
        // Headers
        let action1 = machine.processFrame(frame: self.validRequestHead)
        #expect(
            action1?.returnPart
                == .head(.init(method: .get, scheme: "https", authority: "test", path: "/", headerFields: [:]))
        )

        // Data
        for _ in 0...numDataFrames {
            let action2 = machine.processFrame(frame: .data(.init()))
            #expect(action2?.returnPart == .body(.init()))
        }

        // Trailers
        let action3 = machine.processFrame(frame: self.validTrailers)
        #expect(action3?.returnPart == .end([.init("test")!: "hello"]))
    }

    @Test(arguments: 1...10)
    func testProcessResponseFramesWithTrailers(numDataFrames: Int) throws {
        var machine = HTTPMessageParsingStateMachine<HTTPResponsePart>()
        // Headers
        let action1 = machine.processFrame(frame: self.validResponseHead)
        #expect(
            action1?.returnPart
                == .head(.init(status: .ok))
        )

        // Data
        for _ in 0...numDataFrames {
            let action2 = machine.processFrame(frame: .data(.init()))
            #expect(action2?.returnPart == .body(.init()))
        }

        // Trailers
        let action3 = machine.processFrame(frame: self.validTrailers)
        #expect(action3?.returnPart == .end([.init("test")!: "hello"]))
    }

    @Test
    func testProcessInvalidHeaders() throws {
        var machine = HTTPMessageParsingStateMachine<HTTPRequestPart>()
        // Headers
        let action1 = machine.processFrame(frame: .headers([]))  // Invalid because missing required headers
        action1.assertError { error in
            expectH3ErrorEqual(
                error: error,
                expectedCode: .malformedMessage,
                expectedH3ErrorCode: .H3_MESSAGE_ERROR,
                expectedMessage: "Invalid headers",
                verifyCause: { #expect($0.map(String.init(describing:)) == "requestWithoutMethod") }
            )
        }

        // Now even valid headers will return no action
        let action2 = machine.processFrame(frame: self.validRequestHead)
        #expect(action2 == nil)
    }

    @Test
    func testProcessInvalidTrailers() throws {
        var machine = HTTPMessageParsingStateMachine<HTTPRequestPart>()
        // Valid headers
        let action1 = machine.processFrame(frame: self.validRequestHead)
        #expect(
            action1?.returnPart
                == .head(.init(method: .get, scheme: "https", authority: "test", path: "/", headerFields: [:]))
        )
        // Invalid trailers
        let action2 = machine.processFrame(frame: self.validRequestHead)  // Invalid because contains pseudo fields
        action2.assertError {
            expectH3ErrorEqual(
                error: $0,
                expectedCode: .malformedMessage,
                expectedH3ErrorCode: .H3_MESSAGE_ERROR,
                expectedMessage: "Invalid trailers",
                verifyCause: { #expect($0.map(String.init(describing:)) == "trailerFieldsWithPseudo") }
            )
        }

        // Now even valid trailers will return no action
        let action3 = machine.processFrame(frame: self.validTrailers)
        #expect(action3 == nil)
    }

    @Test
    func testEmitsEndOnClose() {
        var machine = HTTPMessageParsingStateMachine<HTTPRequestPart>()
        let action1 = machine.processFrame(frame: self.validRequestHead)
        #expect(
            action1?.returnPart
                == .head(.init(method: .get, scheme: "https", authority: "test", path: "/", headerFields: [:]))
        )
        let action2 = machine.inputClosed()
        guard case .returnPart(.end(nil)) = action2 else {
            Issue.record("Unexpected action \(action2.debugDescription)")
            return
        }
    }

    @Test
    func testNoActionOnCloseAfterTrailers() throws {
        var machine = HTTPMessageParsingStateMachine<HTTPRequestPart>()
        let action1 = machine.processFrame(frame: self.validRequestHead)
        #expect(
            action1?.returnPart
                == .head(.init(method: .get, scheme: "https", authority: "test", path: "/", headerFields: [:]))
        )
        let action2 = machine.processFrame(frame: .headers([]))
        #expect(action2?.returnPart == .end(nil))
        let action3 = machine.inputClosed()
        #expect(action3 == nil)
    }

    let informationalEarlyHintsHead = HTTP3Frame.headers([.init(name: .status, value: "103")])

    @Test
    func testSingleInterimThenFinal() throws {
        var machine = HTTPMessageParsingStateMachine<HTTPResponsePart>()

        let action1 = machine.processFrame(frame: self.informationalEarlyHintsHead)
        #expect(action1?.returnPart == .head(.init(status: .init(code: 103))))

        let action2 = machine.processFrame(frame: self.validResponseHead)
        #expect(action2?.returnPart == .head(.init(status: .ok)))

        let action3 = machine.processFrame(frame: .data(.init()))
        #expect(action3?.returnPart == .body(.init()))

        let action4 = machine.processFrame(frame: self.validTrailers)
        #expect(action4?.returnPart == .end([.init("test")!: "hello"]))
    }

    @Test
    func testMultipleInterimThenFinal() throws {
        var machine = HTTPMessageParsingStateMachine<HTTPResponsePart>()

        let action1 = machine.processFrame(frame: self.informationalEarlyHintsHead)
        #expect(action1?.returnPart == .head(.init(status: .init(code: 103))))

        let action2 = machine.processFrame(frame: self.informationalEarlyHintsHead)
        #expect(action2?.returnPart == .head(.init(status: .init(code: 103))))

        let action3 = machine.processFrame(frame: self.validResponseHead)
        #expect(action3?.returnPart == .head(.init(status: .ok)))

        let action4 = machine.processFrame(frame: .data(.init()))
        #expect(action4?.returnPart == .body(.init()))

        let action5 = machine.processFrame(frame: self.validTrailers)
        #expect(action5?.returnPart == .end([.init("test")!: "hello"]))
    }

    @Test
    func testInvalidInterimHeaders() throws {
        var machine = HTTPMessageParsingStateMachine<HTTPResponsePart>()

        // 1xx response with a forbidden transfer-encoding field.
        let action1 = machine.processFrame(
            frame: .headers([
                .init(name: .status, value: "103"),
                .init(name: .transferEncoding, value: "chunked"),
            ])
        )
        action1.assertError { error in
            expectH3ErrorEqual(
                error: error,
                expectedCode: .malformedMessage,
                expectedH3ErrorCode: .H3_MESSAGE_ERROR,
                expectedMessage: "Invalid headers"
            )
        }

        // After error, even valid final headers are ignored.
        let action2 = machine.processFrame(frame: self.validResponseHead)
        #expect(action2 == nil)
    }

    // MARK: General request and response header validation

    @Test
    func testProcessPseudoNotFirst() {
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .init("test")!, value: "test"),
                // This is invalid because we have the authority pseudo header AFTER a normal header
                .init(name: .authority, value: "test"),
                .init(name: .path, value: "/"),
            ],
            expectedError: "pseudoNotFirst"
        )
        self.assertResponseHeadersNotValid(
            fields: [
                .init(name: .init("test")!, value: "test"),
                // This is invalid because we have the status pseudo header AFTER a normal header
                .init(name: .status, value: "200"),
            ],
            expectedError: "pseudoNotFirst"
        )
    }

    @Test
    func testProcessDuplicatePseudoHeaders() {
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .authority, value: "test"),
                .init(name: .path, value: "/"),
            ],
            expectedError: "multiplePseudo"
        )
        self.assertResponseHeadersNotValid(
            fields: [
                .init(name: .status, value: "200"),
                .init(name: .status, value: "200"),
            ],
            expectedError: "multiplePseudo"
        )
    }

    @Test
    func testTeHeader() {
        /// The only exception to this is the TE header field, which MAY be present in an HTTP/3 request header; when it is, it MUST NOT contain any value other than "trailers".
        self.assertRequestHeadersValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .authority, value: "test"),
                .init(name: .path, value: "/"),
                .init(name: .te, value: "trailers"),
            ]
        )
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .authority, value: "test"),
                .init(name: .path, value: "/"),
                .init(name: .te, value: "bla"),
            ],
            expectedError: "te field must contain trailers if present"
        )
        // Response can never have te
        self.assertResponseHeadersNotValid(
            fields: [
                .init(name: .status, value: "200"),
                .init(name: .te, value: "trailers"),
            ],
            expectedError: "te field must not be present"
        )
    }

    @Test
    func testTransferEncoding() {
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .authority, value: "test"),
                .init(name: .path, value: "/"),
                .init(name: .transferEncoding, value: "anything"),
            ],
            expectedError: "transfer-encoding field must not be present"
        )
        self.assertResponseHeadersNotValid(
            fields: [
                .init(name: .status, value: "200"),
                .init(name: .transferEncoding, value: "anything"),
            ],
            expectedError: "transfer-encoding field must not be present"
        )
    }

    @Test
    func testUnknownHeaders() {
        self.assertRequestHeadersValid(fields: [
            .init(name: .method, value: "GET"),
            .init(name: .scheme, value: "https"),
            .init(name: .authority, value: "test"),
            .init(name: .path, value: "/"),
            // This is fine because it's not a pseudo field
            .init(name: .init(parsed: "blabla")!, value: "something"),
        ])
        self.assertRequestHeadersNotValid(
            fields: [
                // This is not fine, it's an unknown pseudo field
                .init(name: .init(parsed: ":blabla")!, value: "something")
            ],
            expectedError: "invalidPseudoName"
        )
        self.assertResponseHeadersValid(fields: [
            .init(name: .status, value: "200"),
            // This is fine because it's not a pseudo field
            HTTPField(name: .init(parsed: "blabla")!, value: "something"),
        ])
        self.assertRequestHeadersNotValid(
            fields: [
                // This is not fine, it's an unknown pseudo field
                .init(name: .status, value: "200"),
                .init(name: .init(parsed: ":blabla")!, value: "something"),
            ],
            expectedError: "invalidPseudoName"
        )
    }

    // MARK: Request-specific header validation

    @Test
    func testRequestWithResponsePseudo() {
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .authority, value: "test"),
                .init(name: .path, value: "/"),
                .init(name: .status, value: "200"),  // Request shouldn't have status
            ],
            expectedError: "requestWithResponsePseudo"
        )
    }

    @Test
    func testHTTPMustHaveAuthorityHost() {
        // Missing authority and host
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .path, value: "/"),
            ],
            expectedError: "Missing host and authority"
        )

        // Blank authority
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .authority, value: ""),
                .init(name: .path, value: "/"),
            ],
            expectedError: "authority field is empty"
        )

        // Blank host
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .path, value: "/"),
                .init(name: .init(parsed: "host")!, value: ""),
            ],
            expectedError: "host field is empty"
        )

        // Has authority
        self.assertRequestHeadersValid(fields: [
            .init(name: .method, value: "GET"),
            .init(name: .scheme, value: "https"),
            .init(name: .authority, value: "test"),
            .init(name: .path, value: "/"),
        ])

        // Has host
        self.assertRequestHeadersValid(fields: [
            .init(name: .method, value: "GET"),
            .init(name: .scheme, value: "https"),
            .init(name: .path, value: "/"),
            .init(name: .init(parsed: "host")!, value: "test"),
        ])

        // Has both
        self.assertRequestHeadersValid(fields: [
            .init(name: .method, value: "GET"),
            .init(name: .scheme, value: "https"),
            .init(name: .path, value: "/"),
            .init(name: .authority, value: "test"),
            .init(name: .init(parsed: "host")!, value: "test"),
        ])

        // Has both, mismatched
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: "https"),
                .init(name: .path, value: "/"),
                .init(name: .authority, value: "test1"),
                .init(name: .init(parsed: "host")!, value: "test2"),
            ],
            expectedError: "Mismatched authority and host"
        )
    }

    @Test(arguments: [
        (scheme: "http", path: ""),
        (scheme: "https", path: ""),
    ])
    func testMustHaveNonEmptyPathIfHTTP(failingTestCase: (scheme: String, path: String)) {
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),
                .init(name: .scheme, value: failingTestCase.scheme),
                .init(name: .path, value: failingTestCase.path),
                .init(name: .authority, value: "test"),
            ],
            expectedError: "Path field is empty"
        )
    }

    @Test(arguments: [
        (scheme: "http", path: "/"),
        (scheme: "https", path: "/"),
        (scheme: "something", path: "/"),
        // For non-http schemes, path can be blank
        (scheme: "something", path: ""),
    ])
    func testMustHaveNonEmptyPathIfHTTP(passingTestCase: (scheme: String, path: String)) {
        self.assertRequestHeadersValid(fields: [
            .init(name: .method, value: "GET"),
            .init(name: .scheme, value: passingTestCase.scheme),
            .init(name: .path, value: passingTestCase.path),
            .init(name: .authority, value: "test"),
        ])
    }

    @Test
    func testConnect() {
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "CONNECT"),
                .init(name: .path, value: "/"),
                .init(name: .authority, value: "test"),
            ],
            expectedError: "CONNECT request must not contain path or scheme"
        )
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "CONNECT"),
                .init(name: .scheme, value: "/"),
                .init(name: .authority, value: "test"),
            ],
            expectedError: "CONNECT request must not contain path or scheme"
        )
        self.assertRequestHeadersNotValid(
            fields: [
                .init(name: .method, value: "CONNECT")
            ],
            expectedError: "CONNECT request must contain authority"
        )
        self.assertRequestHeadersValid(fields: [
            .init(name: .method, value: "CONNECT"),
            .init(name: .authority, value: "test"),
        ])
    }

    // MARK: Response-specific header validation

    @Test
    func testResponseWithRequestPseudo() {
        self.assertResponseHeadersNotValid(
            fields: [
                .init(name: .path, value: "/"),  // Response shouldn't have path
                .init(name: .status, value: "200"),
            ],
            expectedError: "responseWithRequestPseudo"
        )

        self.assertResponseHeadersNotValid(
            fields: [
                .init(name: .authority, value: "test"),  // Response shouldn't have authority
                .init(name: .status, value: "200"),
            ],
            expectedError: "responseWithRequestPseudo"
        )

        self.assertResponseHeadersNotValid(
            fields: [
                .init(name: .method, value: "GET"),  // Response shouldn't have method
                .init(name: .status, value: "200"),
            ],
            expectedError: "responseWithRequestPseudo"
        )

        self.assertResponseHeadersNotValid(
            fields: [
                .init(name: .scheme, value: "/"),  // Response shouldn't have scheme
                .init(name: .status, value: "200"),
            ],
            expectedError: "responseWithRequestPseudo"
        )
    }

    // MARK: Trailer validation

    @Test(arguments: [
        HTTPField(name: .method, value: "GET"),
        HTTPField(name: .authority, value: "test"),
        HTTPField(name: .scheme, value: "https"),
        HTTPField(name: .path, value: "/"),
        HTTPField(name: .status, value: "200"),
    ])
    func testTrailersNoPseudo(testHeader: HTTPField) throws {
        // Requests
        var machine1 = HTTPMessageParsingStateMachine<HTTPRequestPart>()
        _ = machine1.processFrame(frame: self.validRequestHead)
        let action1 = machine1.processFrame(frame: .headers([testHeader]))
        action1?.assertError {
            expectH3ErrorEqual(
                error: $0,
                expectedCode: .malformedMessage,
                expectedH3ErrorCode: .H3_MESSAGE_ERROR,
                expectedMessage: "Invalid trailers",
                verifyCause: { #expect($0.map(String.init(describing:)) == "trailerFieldsWithPseudo") }
            )
        }

        // Responses
        var machine2 = HTTPMessageParsingStateMachine<HTTPResponsePart>()
        _ = machine2.processFrame(frame: self.validResponseHead)
        let action2 = machine2.processFrame(frame: .headers([testHeader]))
        action2?.assertError {
            expectH3ErrorEqual(
                error: $0,
                expectedCode: .malformedMessage,
                expectedH3ErrorCode: .H3_MESSAGE_ERROR,
                expectedMessage: "Invalid trailers",
                verifyCause: { #expect($0.map(String.init(describing:)) == "trailerFieldsWithPseudo") }
            )
        }
    }

    // MARK: Assertions

    private func assertRequestHeadersNotValid(
        fields: [HTTPField],
        expectedError: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var machine = HTTPMessageParsingStateMachine<HTTPRequestPart>()
        let action = machine.processFrame(frame: .headers(fields))
        action.assertError(sourceLocation: sourceLocation) { error in
            expectH3ErrorEqual(
                error: error,
                expectedCode: .malformedMessage,
                expectedH3ErrorCode: .H3_MESSAGE_ERROR,
                expectedMessage: "Invalid headers",
                verifyCause: { #expect($0.map(String.init(describing:)) == expectedError) },
                sourceLocation: sourceLocation
            )
        }
    }

    private func assertResponseHeadersNotValid(
        fields: [HTTPField],
        expectedError: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var machine = HTTPMessageParsingStateMachine<HTTPResponsePart>()
        let action = machine.processFrame(frame: .headers(fields))
        action.assertError(sourceLocation: sourceLocation) { error in
            expectH3ErrorEqual(
                error: error,
                expectedCode: .malformedMessage,
                expectedH3ErrorCode: .H3_MESSAGE_ERROR,
                expectedMessage: "Invalid headers",
                verifyCause: { #expect($0.map(String.init(describing:)) == expectedError) },
                sourceLocation: sourceLocation
            )
        }
    }

    private func assertRequestHeadersValid(
        fields: [HTTPField],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var machine = HTTPMessageParsingStateMachine<HTTPRequestPart>()
        let action = machine.processFrame(frame: .headers(fields))
        switch action {
        case .returnPart:
            break
        case .emitError(let error):
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        case .none:
            Issue.record("Unexpected nil", sourceLocation: sourceLocation)
        }
    }

    private func assertResponseHeadersValid(
        fields: [HTTPField],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var machine = HTTPMessageParsingStateMachine<HTTPResponsePart>()
        let action = machine.processFrame(frame: .headers(fields))
        switch action {
        case .returnPart:
            break
        case .emitError(let error):
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        case .none:
            Issue.record("Unexpected nil", sourceLocation: sourceLocation)
        }
    }
}

extension HTTPMessageParsingStateMachine.ProcessFrameAction {
    fileprivate var returnPart: Part? {
        switch self {
        case .returnPart(let part): return part
        case .emitError: return nil
        }
    }

    fileprivate func assertError(
        _ verifier: (HTTP3Error) -> Void = { _ in },
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch self {
        case .emitError(let error):
            verifier(error)
        default: Issue.record("Expected an error action, got \(self)", sourceLocation: sourceLocation)
        }
    }
}

extension HTTPMessageParsingStateMachine<HTTPRequestPart>.ProcessFrameAction? {
    fileprivate func assertError(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ verifier: (HTTP3Error) -> Void = { _ in }
    ) {
        switch self {
        case .some(let action): action.assertError(verifier, sourceLocation: sourceLocation)
        case .none: Issue.record("Expected error, got no action", sourceLocation: sourceLocation)
        }
    }
}

extension HTTPMessageParsingStateMachine<HTTPResponsePart>.ProcessFrameAction? {
    fileprivate func assertError(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ verifier: (HTTP3Error) -> Void = { _ in }
    ) {
        switch self {
        case .some(let action): action.assertError(verifier, sourceLocation: sourceLocation)
        case .none: Issue.record("Expected error, got no action", sourceLocation: sourceLocation)
        }
    }
}

extension HTTPMessageParsingStateMachine.InputClosedAction {
    fileprivate func assertIncomplete(sourceLocation: SourceLocation = #_sourceLocation) {
        switch self {
        case .messageIncomplete:
            break
        default: Issue.record("Expected .messageIncomplete, got \(self)", sourceLocation: sourceLocation)
        }
    }
}

extension HTTPMessageParsingStateMachine<HTTPRequestPart>.InputClosedAction? {
    fileprivate func assertIncomplete(sourceLocation: SourceLocation = #_sourceLocation) {
        switch self {
        case .some(let action): action.assertIncomplete(sourceLocation: sourceLocation)
        case .none: Issue.record("Expected .messageIncomplete, got no action", sourceLocation: sourceLocation)
        }
    }
}

extension HTTPMessageParsingStateMachine<HTTPResponsePart>.InputClosedAction? {
    fileprivate func assertIncomplete(sourceLocation: SourceLocation = #_sourceLocation) {
        switch self {
        case .some(let action): action.assertIncomplete(sourceLocation: sourceLocation)
        case .none: Issue.record("Expected .messageIncomplete, got no action", sourceLocation: sourceLocation)
        }
    }
}
