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

@_spi(PackageInternal) @testable import HTTP3

/// How far the inbound message has got.
enum InboundProgress: CaseIterable, Sendable {
    case awaitingHead
    case awaitingBodyOrTrailers
    case ended
}

struct HTTP3RequestStreamValidatorTests {
    /// A validator whose inbound message got as far as `progress`.
    @available(anyAppleOS 27, *)
    static func makeValidator(
        _ connectionType: HTTP3ConnectionType,
        inbound progress: InboundProgress = .awaitingHead
    ) -> HTTP3RequestStreamValidator {
        var validator = HTTP3RequestStreamValidator(connectionType: connectionType)
        #expect(validator.connectionType == connectionType)
        if progress != .awaitingHead {
            validator.expectReceivedHead()
        }
        if progress == .ended {
            #expect(validator.receivedFrame(.headers).kind == .decodeTrailers)
        }
        return validator
    }

    // MARK: Inbound

    /// Interim responses keep a client waiting for the final head.
    @available(anyAppleOS 27, *)
    @Test(arguments: [(HTTP3ConnectionType.server, 0), (.client, 0), (.client, 3)])
    func inboundMessage(connectionType: HTTP3ConnectionType, interimResponses: Int) throws {
        var validator = Self.makeValidator(connectionType)
        for _ in 0..<interimResponses {
            // Stop here otherwise: only a HEADERS frame announced by `.decodeHead` may be received as a head.
            try #require(validator.receivedFrame(.headers).kind == .decodeHead)
            validator.receivedHead(informational: true)
        }
        // The final head is still to come, and interim responses have no body.
        #expect(validator.receivedFrame(.data).kind == .connectionError)

        validator.expectReceivedHead()
        for _ in 0..<3 {
            #expect(validator.receivedFrame(.data).kind == .body)
        }
        #expect(validator.receivedFrame(.headers).kind == .decodeTrailers)
    }

    /// The caller records the head announced by `.decodeHead` before it validates the next frame.
    @available(anyAppleOS 27, *)
    @Test func validatingAFrameBeforeRecordingTheHeadTraps() async {
        await #expect(processExitsWith: .failure) {
            var validator = HTTP3RequestStreamValidator(connectionType: .server)
            _ = validator.receivedFrame(.headers)
            _ = validator.receivedFrame(.data)
        }
    }

    /// Only a head announced by `.decodeHead` may be recorded.
    @available(anyAppleOS 27, *)
    @Test func recordingAnUnannouncedHeadTraps() async {
        await #expect(processExitsWith: .failure) {
            var validator = HTTP3RequestStreamValidator(connectionType: .client)
            validator.receivedHead(informational: false)
        }
    }

    /// Only a client receives interim responses, so a server's head is never informational.
    @available(anyAppleOS 27, *)
    @Test func recordingAnInformationalRequestHeadTraps() async {
        await #expect(processExitsWith: .failure) {
            var validator = HTTP3RequestStreamValidator(connectionType: .server)
            _ = validator.receivedFrame(.headers)
            validator.receivedHead(informational: true)
        }
    }

    /// Frames which aren't allowed now are rejected, unknown frames are ignored, and neither changes the state.
    @available(anyAppleOS 27, *)
    @Test(arguments: [HTTP3ConnectionType.client, .server], InboundProgress.allCases)
    func unexpectedAndUnknownFrames(connectionType: HTTP3ConnectionType, progress: InboundProgress) {
        var validator = Self.makeValidator(connectionType, inbound: progress)
        let message = connectionType == .server ? "request" : "response"
        let (expected, unexpected, nextHeaders): (String, [HTTP3FrameType], InboundFrameActionKind) =
            switch progress {
            case .awaitingHead: ("headers", [.data], .decodeHead)
            case .awaitingBodyOrTrailers: ("headers or data", [], .decodeTrailers)
            case .ended: ("no further frames after \(message) trailers", [.data, .headers], .connectionError)
            }
        // RFC 9114 § 7.2: SETTINGS, GOAWAY, MAX_PUSH_ID and CANCEL_PUSH are only allowed on the control stream.
        for type in unexpected + [.settings, .goaway, .maxPushID, .cancelPush] {
            expectH3ErrorEqual(
                error: validator.receivedFrame(type).connectionError,
                expectedCode: .unexpectedFrame,
                expectedH3ErrorCode: .frameUnexpected,
                expectedMessage: "Expected \(expected), got \(type)"
            )
        }

        // A client must never send a PUSH_PROMISE frame. We never send MAX_PUSH_ID, so a server's push ID is always
        // one we didn't allow.
        let isServer = connectionType == .server
        expectH3ErrorEqual(
            error: validator.receivedFrame(.pushPromise).connectionError,
            expectedCode: .unexpectedFrame,
            expectedH3ErrorCode: isServer ? .frameUnexpected : .idError,
            expectedMessage: isServer ? "Expected \(expected), got pushPromise" : "Unexpected push promise"
        )

        #expect(validator.receivedFrame(.unknown(type: 0x21)).kind == .ignore)
        #expect(validator.receivedFrame(.unknown(type: 0xdb)).kind == .ignore)
        #expect(validator.receivedFrame(.headers).kind == nextHeaders)
    }

    // MARK: Inbound end

    /// A request which ended before its head is a stream error. A response which ended before its final head is not.
    /// A head which was announced but not recorded hasn't been received.
    @available(anyAppleOS 27, *)
    @Test(arguments: [
        (HTTP3ConnectionType.server, 0, false), (.client, 0, false), (.client, 1, false), (.client, 2, false),
        (.server, 0, true), (.client, 0, true), (.client, 1, true), (.client, 2, true),
    ])
    func messageEndsBeforeFinalHead(
        connectionType: HTTP3ConnectionType,
        interimResponses: Int,
        headAnnounced: Bool
    ) throws {
        var validator = Self.makeValidator(connectionType)
        for _ in 0..<interimResponses {
            try #require(validator.receivedFrame(.headers).kind == .decodeHead)
            validator.receivedHead(informational: true)
        }
        if headAnnounced {
            try #require(validator.receivedFrame(.headers).kind == .decodeHead)
        }
        let error: HTTP3Error? =
            switch validator.receivedEnd() {
            case .incompleteRequest(let error) where connectionType == .server,
                .incompleteResponse(let error) where connectionType == .client:
                error
            case .complete, .incompleteRequest, .incompleteResponse: nil
            }
        let message = connectionType == .server ? "request" : "response"
        expectH3ErrorEqual(
            error: error,
            expectedCode: .peerTerminatedInboundStream,
            expectedH3ErrorCode: connectionType == .server ? .requestIncomplete : nil,
            expectedMessage: "Inbound \(message) stream closed before a complete \(message) was received"
        )
    }

    /// The FIN may follow the head or the trailers, and ends the message.
    @available(anyAppleOS 27, *)
    @Test(arguments: [HTTP3ConnectionType.client, .server], [InboundProgress.awaitingBodyOrTrailers, .ended])
    func messageEnds(connectionType: HTTP3ConnectionType, progress: InboundProgress) {
        var validator = Self.makeValidator(connectionType, inbound: progress)
        #expect(validator.receivedEnd().isComplete)
        #expect(validator.receivedFrame(.data).kind == .connectionError)
        #expect(validator.receivedEnd().isComplete)
    }
}

@available(anyAppleOS 27, *)
extension HTTP3RequestStreamValidator {
    /// Receives a final head.
    fileprivate mutating func expectReceivedHead(sourceLocation: SourceLocation = #_sourceLocation) {
        // Only a HEADERS frame announced by `.decodeHead` may be received as a head.
        guard self.receivedFrame(.headers).kind == .decodeHead else {
            Issue.record("HEADERS weren't announced as a head", sourceLocation: sourceLocation)
            return
        }
        self.receivedHead(informational: false)
    }
}

// This works around the issue that `HTTP3RequestStreamValidator.InboundFrameAction`
// is not Equatable. `HTTP3RequestStreamValidator.InboundFrameAction.connectionError`
// has an attached HTTP3 error, which has an underlying internal any Error. Because
// of this we can't make `HTTP3RequestStreamValidator.InboundFrameAction` `Equatable`.
enum InboundFrameActionKind {
    case decodeHead
    case decodeTrailers
    case body
    case ignore
    case connectionError
}

@available(anyAppleOS 27, *)
extension HTTP3RequestStreamValidator.InboundFrameAction {
    var kind: InboundFrameActionKind {
        switch self {
        case .decodeHead: return .decodeHead
        case .decodeTrailers: return .decodeTrailers
        case .body: return .body
        case .ignore: return .ignore
        case .connectionError: return .connectionError
        }
    }

    var connectionError: HTTP3Error? {
        if case .connectionError(let error) = self { error } else { nil }
    }
}

@available(anyAppleOS 27, *)
extension HTTP3RequestStreamValidator.InboundEndAction {
    var isComplete: Bool {
        if case .complete = self { true } else { false }
    }
}
