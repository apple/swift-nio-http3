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

package import HTTP3
import Testing

struct HTTP3FrameValidatorTests {
    static func validRequestHeaders() -> HTTP3Frame {
        .headers([
            .init(name: .method, value: "GET"),
            .init(name: .path, value: "/"),
            .init(name: .scheme, value: "https"),
            .init(name: .authority, value: "example.com"),
        ])
    }

    static func validResponseHeaders() -> HTTP3Frame {
        .headers([
            .init(name: .status, value: "200")
        ])
    }

    static func validTrailers() -> HTTP3Frame {
        .headers([
            .init(name: .init("test")!, value: "something")
        ])
    }

    static func makeTestDataFrame() -> HTTP3Frame {
        .data(.init())
    }

    // MARK: Request stream

    @Test
    func testValidRequestWithNoData() {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)
        let testHeaders = Self.validRequestHeaders()
        let action = validator.processInboundFrame(testHeaders)
        #expect(action == .forwardFrame(testHeaders))
    }

    @Test
    func testValidRequestWithManyData() {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)

        validator.assertInboundFramePassesThrough(Self.validRequestHeaders())

        for _ in 0...50 {
            validator.assertInboundFramePassesThrough(Self.makeTestDataFrame())
        }
    }

    // Any number of data frames, including 0, is ok between headers and trailers
    @Test(arguments: 0...50)
    func testValidRequestWithTrailers(numberOfDataFrames: Int) {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)

        validator.assertInboundFramePassesThrough(Self.validRequestHeaders())

        for _ in 0...numberOfDataFrames {
            validator.assertInboundFramePassesThrough(Self.makeTestDataFrame())
        }

        validator.assertInboundFramePassesThrough(Self.validTrailers())
    }

    @Test(arguments: [
        HTTP3Frame.cancelPush(1),
        .goaway(2),
        .settings(.init()),
        .data(.init()),
        .maxPushID(1),
        .pushPromise(.init(pushID: 12, httpFields: [:])),
    ])
    func testInvalidRequest_anythingBeforeHeaders(testFrame: HTTP3Frame) {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)
        let action = validator.processInboundFrame(testFrame)
        expectH3ErrorEqual(
            error: action.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Expected headers, got \(testFrame.type)"
        )
        // now, even sending valid headers will give no action due to previous error
        #expect(validator.processInboundFrame(Self.validRequestHeaders()) == .previousError)
    }

    @Test
    func testValidRequestWithUnknownFrames() {
        // 4.1: Frames of unknown types (Section 9), including reserved frames (Section 7.2.8) MAY be sent on a request or push stream before, after, or interleaved with other frames described in this section.
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)

        // Read a request, interleaved with unknown frames
        validator.assertInboundUnknownFrameDropped()
        validator.assertInboundFramePassesThrough(Self.validRequestHeaders())
        validator.assertInboundUnknownFrameDropped()
        validator.assertInboundFramePassesThrough(Self.makeTestDataFrame())
        validator.assertInboundUnknownFrameDropped()
        validator.assertInboundFramePassesThrough(Self.validTrailers())
        validator.assertInboundUnknownFrameDropped()
    }

    @Test
    func testValidResponseWithUnknownFrames() {
        // 4.1: Frames of unknown types (Section 9), including reserved frames (Section 7.2.8) MAY be sent on a request or push stream before, after, or interleaved with other frames described in this section.
        var validator = HTTP3FrameValidator(streamType: .request, incoming: false)

        // write request header
        validator.assertOutboundFramePassesThrough(Self.validRequestHeaders())

        // Receive response parts, interleaved with unknown frames
        validator.assertInboundUnknownFrameDropped()
        validator.assertInboundFramePassesThrough(Self.validResponseHeaders())
        validator.assertInboundUnknownFrameDropped()
        validator.assertInboundFramePassesThrough(Self.makeTestDataFrame())
        validator.assertInboundUnknownFrameDropped()
        validator.assertInboundFramePassesThrough(Self.validTrailers())
        validator.assertInboundUnknownFrameDropped()
    }

    @Test(arguments: [
        HTTP3Frame.cancelPush(1),
        .goaway(2),
        .settings(.init()),
        .maxPushID(1),
        .pushPromise(.init(pushID: 1, httpFields: [:])),
    ])
    func testInvalidRequest_invalidAfterHeaders(testFrame: HTTP3Frame) {
        // After headers, must be body or trailers
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)
        validator.assertInboundFramePassesThrough(Self.validRequestHeaders())  // headers

        let action2 = validator.processInboundFrame(testFrame)
        expectH3ErrorEqual(
            error: action2.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Expected headers or data, got \(testFrame.type)"
        )

        // now, even sending valid body will give no action due to previous error
        #expect(validator.processInboundFrame(Self.makeTestDataFrame()) == .previousError)
    }

    @Test(arguments: [
        Self.validRequestHeaders(),
        .cancelPush(1),
        .goaway(2),
        .settings(.init()),
        .data(.init()),
        .maxPushID(1),
        .pushPromise(.init(pushID: 12, httpFields: [:])),
    ])
    func testInvalidRequest_anythingAfterTrailers(testFrame: HTTP3Frame) {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)

        validator.assertInboundFramePassesThrough(Self.validRequestHeaders())  // headers
        validator.assertInboundFramePassesThrough(Self.validTrailers())  // trailers

        let action1 = validator.processInboundFrame(testFrame)
        expectH3ErrorEqual(
            error: action1.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Expected no further frames after request trailers, got \(testFrame.type)"
        )
    }

    @Test
    func testInvalidRequest_doubleTrailers() {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)

        validator.assertInboundFramePassesThrough(Self.validRequestHeaders())
        validator.assertInboundFramePassesThrough(Self.validTrailers())
        let action3 = validator.processInboundFrame(Self.validTrailers())
        expectH3ErrorEqual(
            error: action3.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Expected no further frames after request trailers, got headers"
        )
    }

    @Test
    func testResponseBeforeRequest() {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)
        let action = validator.processOutboundFrame(Self.validResponseHeaders())
        expectH3ErrorEqual(
            error: action.streamError,
            expectedCode: .malformedMessage,
            expectedH3ErrorCode: .H3_MESSAGE_ERROR,
            expectedMessage: "A HTTP response was sent before a request"
        )
    }

    @Test
    func testResponseAfterRequestHeaders() {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: false)
        validator.assertOutboundFramePassesThrough(Self.validRequestHeaders())  // write req headers
        validator.assertInboundFramePassesThrough(Self.validResponseHeaders())  // read response headers
    }

    @Test(arguments: 1...10)
    func testResponseWithTrailers(dataCount: Int) {
        // Any number of data frames, including 0, is valid before the trailers
        var validator = HTTP3FrameValidator(streamType: .request, incoming: false)

        validator.assertOutboundFramePassesThrough(Self.validRequestHeaders())  // write req headers
        validator.assertInboundFramePassesThrough(Self.validResponseHeaders())  // read response headers

        // read response body
        for _ in 0...dataCount {
            validator.assertInboundFramePassesThrough(.data(.init()))  // read response data
        }

        validator.assertInboundFramePassesThrough(Self.validTrailers())  // read response trailers
    }

    @Test(arguments: [
        Self.validResponseHeaders(),
        .cancelPush(1),
        .goaway(2),
        .settings(.init()),
        .data(.init()),
        .maxPushID(1),
        .pushPromise(.init(pushID: 12, httpFields: [:])),
    ])
    func testInvalidResponse_anythingAfterTrailers(testFrame: HTTP3Frame) {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: false)

        // we need to write a request head first, before we can test responses
        validator.assertOutboundFramePassesThrough(Self.validRequestHeaders())

        // response head and trailers
        validator.assertInboundFramePassesThrough(Self.validResponseHeaders())  // headers
        validator.assertInboundFramePassesThrough(Self.validTrailers())  // trailers

        // an extra frame which isn't allowed
        let action3 = validator.processInboundFrame(testFrame)
        expectH3ErrorEqual(
            error: action3.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Expected no further frames after response trailers, got \(testFrame.type)"
        )
    }

    /// After headers, must be body or trailers.
    @Test(arguments: [
        HTTP3Frame.cancelPush(1),
        .goaway(2),
        .settings(.init()),
        .maxPushID(1),
        .pushPromise(.init(pushID: 1, httpFields: [:])),
    ])
    func testResponseInvalidAfterHeaders(testFrame: HTTP3Frame) {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)
        validator.assertInboundFramePassesThrough(Self.validRequestHeaders())  // request headers
        validator.assertOutboundFramePassesThrough(Self.validResponseHeaders())  // response headers

        let action2 = validator.processOutboundFrame(testFrame)
        expectH3ErrorEqual(
            error: action2.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Expected headers or data, got \(testFrame.type)"
        )

        // now, even sending valid body will give no action due to previous error
        #expect(validator.processOutboundFrame(Self.makeTestDataFrame()) == .previousError)
    }

    @Test(arguments: [
        HTTP3Frame.cancelPush(1),
        .goaway(2),
        .settings(.init()),
        .data(.init()),
        .maxPushID(1),
        .pushPromise(.init(pushID: 12, httpFields: [:])),
    ])
    func testInvalidResponse_anythingBeforeHead(testFrame: HTTP3Frame) {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: false)
        // we need to send a request first
        validator.assertOutboundFramePassesThrough(Self.validRequestHeaders())
        let action = validator.processInboundFrame(testFrame)
        expectH3ErrorEqual(
            error: action.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Expected headers, got \(testFrame.type)"
        )
        // now, even sending valid headers will give no action due to previous error
        #expect(validator.processInboundFrame(Self.validResponseHeaders()) == .previousError)
    }

    @Test
    func testInboundInterimResponse() {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: false)
        validator.assertOutboundFramePassesThrough(Self.validRequestHeaders())

        validator.assertInboundFramePassesThrough(.headers([.init(name: .status, value: "103")]))
        validator.assertInboundFramePassesThrough(.headers([.init(name: .status, value: "200")]))
        validator.assertInboundFramePassesThrough(.data(.init(bytes: [1, 2, 3])))
        validator.assertInboundFramePassesThrough(Self.validTrailers())
    }

    @Test
    func testInboundMultipleInterimResponse() {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: false)
        validator.assertOutboundFramePassesThrough(Self.validRequestHeaders())  // write req headers

        // Some informational responses
        validator.assertInboundFramePassesThrough(.headers([.init(name: .status, value: "100")]))
        validator.assertInboundFramePassesThrough(.headers([.init(name: .status, value: "100")]))
        validator.assertInboundFramePassesThrough(.headers([.init(name: .status, value: "102")]))
        validator.assertInboundFramePassesThrough(.headers([.init(name: .status, value: "103")]))
        // Final response
        validator.assertInboundFramePassesThrough(.headers([.init(name: .status, value: "200")]))
        validator.assertInboundFramePassesThrough(.data(.init(bytes: [1, 2, 3])))
        validator.assertInboundFramePassesThrough(.headers([.init(name: .cookie, value: "test")]))
    }

    @Test
    func testOutboundInterimResponse() {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)
        validator.assertInboundFramePassesThrough(Self.validRequestHeaders())

        validator.assertOutboundFramePassesThrough(.headers([.init(name: .status, value: "103")]))
        validator.assertOutboundFramePassesThrough(.headers([.init(name: .status, value: "200")]))
        validator.assertOutboundFramePassesThrough(.data(.init(bytes: [1, 2, 3])))
    }

    @Test
    func testOutboundMultipleInterimResponses() {
        var validator = HTTP3FrameValidator(streamType: .request, incoming: true)
        validator.assertInboundFramePassesThrough(Self.validRequestHeaders())

        // Some informational responses
        validator.assertOutboundFramePassesThrough(.headers([.init(name: .status, value: "100")]))
        validator.assertOutboundFramePassesThrough(.headers([.init(name: .status, value: "100")]))
        validator.assertOutboundFramePassesThrough(.headers([.init(name: .status, value: "102")]))
        validator.assertOutboundFramePassesThrough(.headers([.init(name: .status, value: "103")]))
        // Final response
        validator.assertOutboundFramePassesThrough(.headers([.init(name: .status, value: "200")]))
        validator.assertOutboundFramePassesThrough(.data(.init(bytes: [1, 2, 3])))
        validator.assertOutboundFramePassesThrough(.headers([.init(name: .cookie, value: "test")]))
    }

    // MARK: Control stream

    /// Anything other than settings is invalid to be the first frame.
    @Test(arguments: [
        .data(.init()),
        .pushPromise(.init(pushID: 12, httpFields: [:])),
        Self.validRequestHeaders(),
        .goaway(1),
        .maxPushID(1),
        .cancelPush(1),
    ])
    func testControlStreamNoSettings(testFrame: HTTP3Frame) {
        var validator = HTTP3FrameValidator(streamType: .control, incoming: true)
        let action = validator.processInboundFrame(testFrame)
        expectH3ErrorEqual(
            error: action.connectionError,
            expectedCode: .firstControlFrameNotSettings,
            expectedH3ErrorCode: .H3_MISSING_SETTINGS,
            expectedMessage: "Expected settings, got \(testFrame.type)"
        )

        // now, even sending valid settings will give no action due to previous error
        #expect(validator.processInboundFrame(.settings(.init())) == .previousError)
    }

    /// Unknown frames are also invalid to be the first frame
    @Test
    func testControlStreamUnknownFrameBeforeSettings() {
        var validator = HTTP3FrameValidator(streamType: .control, incoming: true)
        let action = validator.processInboundUnknownFrame()
        expectH3ErrorEqual(
            error: action.connectionError,
            expectedCode: .firstControlFrameNotSettings,
            expectedH3ErrorCode: .H3_MISSING_SETTINGS,
            expectedMessage: "Expected settings, got unknown"
        )

        // now, even sending valid settings will give no action due to previous error
        #expect(validator.processInboundFrame(.settings(.init())) == .previousError)
    }

    @Test(arguments: [
        // The following frames are valid to send after the initial settings
        HTTP3Frame.goaway(1),
        .maxPushID(1),
        .cancelPush(1),
    ])
    func testControlStreamValidAfterSettings(testFrame: HTTP3Frame) {
        let testSettings = HTTP3Frame.settings(.init(qpackBlockedStreams: 10))
        var validator = HTTP3FrameValidator(streamType: .control, incoming: true)

        validator.assertInboundFramePassesThrough(testSettings)
        validator.assertInboundFramePassesThrough(testFrame)
    }

    @Test
    func testControlStreamUnknownFrameAfterSettings() {
        let testSettings = HTTP3Frame.settings(.init(qpackBlockedStreams: 10))
        var validator = HTTP3FrameValidator(streamType: .control, incoming: true)

        validator.assertInboundFramePassesThrough(testSettings)
        validator.assertInboundUnknownFrameDropped()
    }

    @Test(arguments: [
        // The following frames are invalid to send after settings
        .data(.init()),
        .pushPromise(.init(pushID: 12, httpFields: [:])),
        Self.validRequestHeaders(),
    ])
    func testControlStreamInvalidAfterSettings(testFrame: HTTP3Frame) {
        let testSettings = HTTP3Frame.settings(HTTP3Settings(qpackBlockedStreams: 10))
        var validator = HTTP3FrameValidator(streamType: .control, incoming: true)
        validator.assertInboundFramePassesThrough(testSettings)

        let action2 = validator.processInboundFrame(testFrame)
        expectH3ErrorEqual(
            error: action2.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Expected cancelPush or goaway or maxPushID, got \(testFrame.type)"
        )

        // now, even sending a valid frame will give no action due to previous error
        #expect(validator.processInboundFrame(.goaway(1)) == .previousError)
    }

    @Test
    func testControlStreamDoubleSettings() {
        let testSettings = HTTP3Frame.settings(HTTP3Settings(qpackBlockedStreams: 10))

        var validator = HTTP3FrameValidator(streamType: .control, incoming: true)
        let action1 = validator.processInboundFrame(testSettings)
        #expect(action1 == .forwardFrame(testSettings))

        let action2 = validator.processInboundFrame(testSettings)
        expectH3ErrorEqual(
            error: action2.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Received a second settings frame"
        )
    }

    @Test
    func testControlStreamWrongWay() {
        var incomingValidator = HTTP3FrameValidator(streamType: .control, incoming: true)
        expectH3ErrorEqual(
            error: incomingValidator.processOutboundFrame(.settings(HTTP3Settings())).connectionError,
            expectedCode: .invalidStream,
            expectedH3ErrorCode: nil,
            expectedMessage: "Tried to write on an incoming unidirectional control stream"
        )

        var outgoingValidator = HTTP3FrameValidator(streamType: .control, incoming: false)
        expectH3ErrorEqual(
            error: outgoingValidator.processInboundFrame(.settings(HTTP3Settings())).connectionError,
            expectedCode: .invalidStream,
            expectedH3ErrorCode: nil,
            expectedMessage: "Tried to read on an outgoing unidirectional control stream"
        )
    }

    // MARK: Push stream

    @Test(arguments: [
        // Push streams can only take headers or data (unknown frames are also fine because they have no meaning)
        Self.validRequestHeaders(),
        .data(.init()),
    ])
    func testPushStreamValid(testFrame: HTTP3Frame) {
        var validator = HTTP3FrameValidator(streamType: .push, incoming: true)
        let action = validator.processInboundFrame(testFrame)
        #expect(action == .forwardFrame(testFrame))
    }

    @Test
    func testPushStreamUnknown() {
        var validator = HTTP3FrameValidator(streamType: .push, incoming: true)
        validator.assertInboundUnknownFrameDropped()
    }

    @Test(arguments: [
        // Push streams can only take headers or data. So the following are invalid
        HTTP3Frame.settings(HTTP3Settings()),
        .pushPromise(.init(pushID: 1, httpFields: [:])),
        .goaway(1),
        .maxPushID(1),
        .cancelPush(1),
    ])
    func testPushStreamInvalid(testFrame: HTTP3Frame) {
        var validator = HTTP3FrameValidator(streamType: .push, incoming: true)
        let action = validator.processInboundFrame(testFrame)
        expectH3ErrorEqual(
            error: action.connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: .H3_FRAME_UNEXPECTED,
            expectedMessage: "Expected headers or data, got \(testFrame.type)"
        )
    }

    @Test
    func testPushStreamWrongWay() {
        var incomingValidator = HTTP3FrameValidator(streamType: .push, incoming: true)
        expectH3ErrorEqual(
            error: incomingValidator.processOutboundFrame(.pushPromise(.init(pushID: 1, httpFields: [:])))
                .connectionError,
            expectedCode: .invalidStream,
            expectedH3ErrorCode: nil,
            expectedMessage: "Tried to write on an incoming unidirectional push stream"
        )

        var outgoingValidator = HTTP3FrameValidator(streamType: .push, incoming: false)
        expectH3ErrorEqual(
            error: outgoingValidator.processInboundFrame(.pushPromise(.init(pushID: 1, httpFields: [:])))
                .connectionError,
            expectedCode: .invalidStream,
            expectedH3ErrorCode: nil,
            expectedMessage: "Tried to read on an outgoing unidirectional push stream"
        )
    }

    @Test
    func testFrameDoesntAllocateWhenBoxed() {
        #expect(MemoryLayout<HTTP3Frame>.size <= 24)
    }
}

extension HTTP3FrameValidator {
    // Assert that when an outbound frame is given to the validator, it comes back out exactly as it was, without errors
    fileprivate mutating func assertOutboundFramePassesThrough(
        _ frame: HTTP3Frame,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let action = self.processOutboundFrame(frame)
        #expect(action == .forwardFrame(frame), sourceLocation: sourceLocation)
    }

    // Assert that when an unknown outbound frame is given to the validator, it gets dropped
    fileprivate mutating func assertInboundUnknownFrameDropped(
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let action = self.processInboundUnknownFrame()
        #expect(action == .dropFrame, sourceLocation: sourceLocation)
    }

    // Assert that when an inbound frame is given to the validator, it comes back out exactly as it was, without errors
    fileprivate mutating func assertInboundFramePassesThrough(
        _ frame: HTTP3Frame,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let action = self.processInboundFrame(frame)
        #expect(action == .forwardFrame(frame), sourceLocation: sourceLocation)
    }
}

extension HTTP3FrameValidator.ProcessFrameAction: Equatable {
    package static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.forwardFrame(let l), .forwardFrame(let r)): return l == r
        case (.previousError, .previousError): return true
        case (.emitConnectionError(let l), .emitConnectionError(let r)):
            return l.code == r.code && l.message == r.message
        case (.emitStreamError(let l), .emitStreamError(let r)): return l.code == r.code && l.message == r.message
        case (.forwardFrame, .emitStreamError),
            (.forwardFrame, .emitConnectionError),
            (.emitStreamError, .forwardFrame),
            (.emitStreamError, .emitConnectionError),
            (.emitConnectionError, .forwardFrame),
            (.emitConnectionError, .emitStreamError),
            (.emitStreamError, .previousError),
            (.emitConnectionError, .previousError),
            (.previousError, .forwardFrame),
            (.previousError, .emitConnectionError),
            (.previousError, .emitStreamError),
            (.forwardFrame, .previousError):
            return false
        }
    }

    var connectionError: HTTP3Error? {
        switch self {
        case .emitConnectionError(let e): return e
        default: return nil
        }
    }

    var streamError: HTTP3Error? {
        switch self {
        case .emitStreamError(let e): return e
        default: return nil
        }
    }
}

extension HTTP3FrameValidator.UnknownFrameAction: Equatable {
    package static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.dropFrame, .dropFrame): return true
        case (.previousError, .previousError): return true
        case (.emitConnectionError(let l), .emitConnectionError(let r)):
            return l.code == r.code && l.message == r.message
        case (.dropFrame, .emitConnectionError),
            (.emitConnectionError, .dropFrame),
            (.emitConnectionError, .previousError),
            (.previousError, .dropFrame),
            (.previousError, .emitConnectionError),
            (.dropFrame, .previousError):
            return false
        }
    }

    var connectionError: HTTP3Error? {
        switch self {
        case .emitConnectionError(let e): return e
        default: return nil
        }
    }
}
