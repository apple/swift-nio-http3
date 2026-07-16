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

/// An error thrown by the HTTP/3 library.
///
/// All errors have a high-level ``HTTP3Error/Code-swift.struct`` which identifies the domain.
/// of the error. Errors also include a message describing what went wrong and how to remedy it (if applicable).
/// The ``HTTP3Error/message`` is not static and may include dynamic information.
///
/// Errors may have a ``HTTP3Error/cause``, an underlying error which caused the operation to fail.
public struct HTTP3Error: Error, Sendable {
    /// A high-level error code to provide a broad classification.
    public var code: Code

    /// A message describing what went wrong and how it may be remedied.
    public var message: String

    /// An underlying error which caused the operation to fail. This may include additional details
    /// about the root cause of the failure.
    public var cause: (any Error)?

    /// The http3 error code to be sent to the peer when the connection or stream is closed.
    /// See RFC 9114 § 8.1.
    package var h3ErrorCode: HTTP3ErrorCode?

    /// The location from which this error was thrown.
    public var location: SourceLocation

    package init(
        code: Code,
        message: String,
        cause: (any Error)?,
        errorCode: HTTP3ErrorCode?,
        location: SourceLocation
    ) {
        self.code = code
        self.message = message
        self.cause = cause
        self.h3ErrorCode = errorCode
        self.location = location
    }
}

extension HTTP3Error: CustomStringConvertible {
    public var description: String {
        if let cause = self.cause {
            return "\(self.code): \(self.message) (\(cause))"
        } else {
            return "\(self.code): \(self.message)"
        }
    }
}

extension HTTP3Error: CustomDebugStringConvertible {
    public var debugDescription: String {
        if let cause = self.cause {
            return """
                \(String(reflecting: self.code)): \(String(reflecting: self.message)) \
                (\(String(reflecting: cause)))
                """
        } else {
            return "\(String(reflecting: self.code)): \(String(reflecting: self.message))"
        }
    }
}

extension HTTP3Error {
    private func detailedDescriptionLines() -> [String] {
        // Build up a tree-like description of the error. This allows nested causes to be formatted
        // correctly, especially when they are also HTTP3Errors.
        //
        // An example is:
        //
        //  HTTP3Error: Insufficient bytes
        //  ├─ Reason: Unable to do the thing
        //  ├─ Cause: XYZ failed to foo
        //  └─ Source location: someFunction(someParameter:_:) (SomeFile.swift:314)
        var lines = [
            "HTTP3Error: \(self.code)",
            "├─ Reason: \(self.message)",
        ]

        if let error = self.cause as? Self {
            lines.append("├─ Cause:")
            let causeLines = error.detailedDescriptionLines()
            // We know this will never be empty.
            lines.append("│  └─ \(causeLines.first!)")
            lines.append(contentsOf: causeLines.dropFirst().map { "│     \($0)" })
        } else if let error = self.cause {
            lines.append("├─ Cause: \(String(reflecting: error))")
        }

        lines.append(
            "└─ Source location: \(self.location)"
        )

        return lines
    }

    /// A detailed multi-line description of the error.
    ///
    /// - Returns: A multi-line description of the error.
    public func detailedDescription() -> String {
        self.detailedDescriptionLines().joined(separator: "\n")
    }
}

extension HTTP3Error {
    /// A high level indication of the kind of error being thrown.
    public struct Code: Hashable, Sendable, CustomStringConvertible {
        private enum Wrapped: Hashable, Sendable {
            case invalidFramePayload
            case forbiddenFrameType
            case unexpectedFrame
            case firstControlFrameNotSettings
            case malformedMessage
            case invalidStream
            case unableToFindStreamID
            case leftoverBytes
            case qpackDecoderError
            case qpackEncoderStreamError
            case qpackDecoderStreamError
            case previousError
            case streamCreationError
            case remoteConnectionError
            case remoteStreamError
            case integerTooLarge
            case rejected
            case none
            case invalidGoawayStreamID
            case criticalStreamClosed
            case peerTerminatedStream
        }

        public var description: String {
            String(describing: self.code)
        }

        private var code: Wrapped
        private init(_ code: Wrapped) {
            self.code = code
        }

        /// Unable to decode a HTTP frame payload.
        public static var invalidFramePayload: Self {
            Self(.invalidFramePayload)
        }

        /// A frames type integer is not allowed, as per RFC 9114 § 7.2.8.
        public static var forbiddenFrameType: Self {
            Self(.forbiddenFrameType)
        }

        /// The received frame is not valid on this stream.
        public static var unexpectedFrame: Self {
            Self(.unexpectedFrame)
        }

        /// There was a missing settings frame at the start of the control stream.
        public static var firstControlFrameNotSettings: Self {
            Self(.firstControlFrameNotSettings)
        }

        /// A request/response sequence is malformed, e.g. contains invalid fields or is in the wrong order.
        public static var malformedMessage: Self {
            Self(.malformedMessage)
        }

        /// Tried to send/receive a message on a stream which cannot send/receive messages.
        public static var invalidStream: Self {
            Self(.invalidStream)
        }

        /// Unable to find the stream ID of an incoming QUIC stream. QUIC streams must have the `quicStreamID` channel option set from `NIOQUICHelpers`.
        public static var unableToFindStreamID: Self {
            Self(.unableToFindStreamID)
        }

        /// There are leftover bytes at the end of the stream.
        public static var leftoverBytes: Self {
            Self(.leftoverBytes)
        }

        /// An error occurred when decoding qpack headers.
        public static var qpackDecoderError: Self {
            Self(.qpackDecoderError)
        }

        /// An error occurred when processing an instruction from the encoder stream.
        public static var qpackEncoderStreamError: Self {
            Self(.qpackEncoderStreamError)
        }

        /// An error occurred when processing an instruction from the decoder stream.
        public static var qpackDecoderStreamError: Self {
            Self(.qpackDecoderStreamError)
        }

        /// We refuse to do work because we previously hit an error.
        public static var previousError: Self {
            Self(.previousError)
        }

        /// An error occurred when trying to create a new stream.
        public static var streamCreationError: Self {
            Self(.streamCreationError)
        }

        /// Remote peer sent back a connection error.
        public static var remoteConnectionError: Self {
            Self(.remoteConnectionError)
        }

        /// Remote peer sent back a stream error.
        public static var remoteStreamError: Self {
            Self(.remoteStreamError)
        }

        /// Peer used an integer which is too large. For example, this could be a frame type or payload length.
        public static var integerTooLarge: Self {
            Self(.integerTooLarge)
        }

        /// The server has rejected the request
        public static var rejected: Self {
            Self(.rejected)
        }

        /// No error.
        public static var none: Self {
            Self(.none)
        }

        /// A GOAWAY was sent or received with an invalid ID.
        public static var invalidGoawayStreamID: Self {
            Self(.invalidGoawayStreamID)
        }

        /// A critical stream was closed.
        public static var criticalStreamClosed: Self {
            Self(.criticalStreamClosed)
        }

        /// The peer terminated the stream before delivering a complete request or response.
        public static var peerTerminatedStream: Self {
            Self(.peerTerminatedStream)
        }
    }

    /// A location within source code.
    public struct SourceLocation: Sendable, Hashable, CustomStringConvertible {
        /// The function in which the error was thrown.
        public var function: String

        /// The file in which the error was thrown.
        public var file: String

        /// The line on which the error was thrown.
        public var line: Int

        public var description: String {
            "\(self.function) (\(self.file):\(self.line))"
        }

        public init(function: String, file: String, line: Int) {
            self.function = function
            self.file = file
            self.line = line
        }

        package static func here(function: String = #function, file: String = #fileID, line: Int = #line) -> Self {
            SourceLocation(function: function, file: file, line: line)
        }
    }
}
