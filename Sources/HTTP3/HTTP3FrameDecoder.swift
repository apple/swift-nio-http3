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

import QPACK

package import struct NIOCore.ByteBuffer

/// A decoder for ``HTTP3PartialFrame``.
package struct HTTP3FrameDecoder: ~Copyable {
    package typealias InboundOut = HTTP3PartialFrame

    /// An enum indicating the next step when decoding HTTP/3 frames.
    private enum NextStep: Hashable {
        /// The next step is to decode the frame type.
        case decodeFrameType
        /// The next step is to decode the payload length.
        case decodePayloadLength(type: HTTP3FrameType)
        /// The next step is to decode the payload.
        case decodePayload(type: HTTP3FrameType, length: UInt64)
        /// We need the skip some bytes.
        case skipBytes(length: Int)
        /// The next step is to decode the next `remainingLength` as DATA frames.
        case decodeData(remainingLength: UInt64)
    }

    private enum NextDecodeAction: Hashable {
        /// We need more bytes to decode the next step.
        case waitForMoreBytes
        /// We can continue decoding.
        case continueDecodeLoop
        /// We have decoded the next frame and need to return it.
        case returnFrame(HTTP3PartialFrameOrUnknown)
    }

    /// Indicates the next decoding step.
    private var nextStep: NextStep = .decodeFrameType

    package init() {}

    /// - Note: Any error thrown from here should be treated as a connection-level error.
    /// - Returns: A frame if one can be decoded from the available bytes, or `nil` if more bytes are needed.
    package mutating func decode(buffer: inout ByteBuffer) throws(HTTP3Error) -> HTTP3PartialFrameOrUnknown? {
        while true {
            switch try self.next(buffer: &buffer) {
            case .returnFrame(let frame):
                return frame

            case .waitForMoreBytes:
                return nil

            case .continueDecodeLoop:
                ()
            }
        }
    }

    /// True if this decoder has consumed some bytes to start building up a frame, but has not completed doing so
    package var hasPartialFrame: Bool {
        switch self.nextStep {
        case .decodeFrameType:
            // The frame type is the first thing. If we're waiting for a frame type then we aren't mid-frame
            return false
        case .decodePayloadLength, .decodePayload, .decodeData, .skipBytes:
            // We must have digested some bytes to work out the frame type or length to get here
            // That means we're currently in the middle of parsing a frame
            return true
        }
    }

    private mutating func next(buffer: inout ByteBuffer) throws(HTTP3Error) -> NextDecodeAction {
        switch self.nextStep {
        case .decodeFrameType:
            guard let typeInteger = buffer.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
                return .waitForMoreBytes
            }

            let type = try HTTP3FrameType(rawValue: typeInteger)

            self.nextStep = .decodePayloadLength(type: type)
            return .continueDecodeLoop
        case .decodePayloadLength(let type):
            // We need to read the length as UInt64 because Int might overflow.
            // A QUIC encoded integer is 62-bits and has a max value of 2^62-1.
            guard let length = buffer.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
                return .waitForMoreBytes
            }

            switch type {
            case .data:
                // special case
                self.nextStep = .decodeData(remainingLength: length)
            case .unknown:
                // Special case. We can already return the frame, then skip payload the bytes later.
                // Sense check the payload size first.
                guard length <= type.maximumAcceptableLength else {
                    /// RFC 9114 § 10.5: An endpoint MAY treat activity that is suspicious as a connection error of type H3\_EXCESSIVE\_LOAD, but false positives will result in disrupting valid connections and requests.
                    throw HTTP3Error(
                        code: .invalidFramePayload,
                        message: "Payload too large",
                        cause: nil,
                        errorCode: .excessiveLoad,
                        location: .here()
                    )
                }
                // We know length must fit in an Int now.
                self.nextStep = .skipBytes(length: Int(length))
                return .returnFrame(.unknown)
            default:
                self.nextStep = .decodePayload(type: type, length: length)
            }
            return .continueDecodeLoop
        case .decodeData(let remainingLength):
            // Special case for data. Since data frames are arbitrary, we don't need to buffer the entire frame length.
            // Instead, we can just treat every ByteBuffer that comes in as its own data frame.
            if buffer.readableBytes == 0 && remainingLength != 0 {
                // If we have nothing left in this buffer, we have nothing to do.
                // If we do have some bytes, even if it's not the whole frame, we can emit a partial frame.
                return .waitForMoreBytes
            }
            // We can't read more bytes than we have, nor should we read more than we need.
            let maxToRead = Int(clamping: remainingLength)
            let bytesToRead = min(buffer.readableBytes, maxToRead)
            let slice = buffer.readSlice(length: bytesToRead)!
            // Cast UInt64(bytesToRead) is safe because bytesToRead can't be negative.
            let newRemainingLength = remainingLength - UInt64(bytesToRead)
            if newRemainingLength == 0 {
                // This data frame is complete, move to next frame
                self.nextStep = .decodeFrameType
            } else {
                self.nextStep = .decodeData(remainingLength: newRemainingLength)
            }
            return .returnFrame(.known(.data(slice)))
        case .skipBytes(let remainingLength):
            let readableBytes = buffer.readableBytes
            if readableBytes >= remainingLength {
                buffer.moveReaderIndex(forwardBy: remainingLength)
                // We have finished skipping bytes.
                self.nextStep = .decodeFrameType
            } else {
                buffer.moveReaderIndex(forwardBy: readableBytes)
                let newRemainingLength = remainingLength - readableBytes
                // Need to skip more bytes still.
                self.nextStep = .skipBytes(length: newRemainingLength)
            }
            return .continueDecodeLoop
        case .decodePayload(let type, let length):
            // Make sure the length is not excessive. If it is, drop the frame.
            guard length <= type.maximumAcceptableLength else {
                // RFC 9114 § 10.5: An endpoint MAY treat activity that is suspicious as a connection error of type H3_EXCESSIVE_LOAD,
                // but false positives will result in disrupting valid connections and requests.
                throw HTTP3Error(
                    code: .invalidFramePayload,
                    message: "Payload too large",
                    cause: nil,
                    errorCode: .excessiveLoad,
                    location: .here()
                )
            }

            // We now know, because of the way we choose maxSize, that `length` can fit in an Int
            let length = Int(length)

            // We know the length of the payload so we can wait for the whole thing to be available
            guard var payload = buffer.readSlice(length: length) else {
                return .waitForMoreBytes
            }
            self.nextStep = .decodeFrameType

            guard let frame = try payload.readHTTP3Frame(type: type) else {
                throw HTTP3Error(
                    code: .invalidFramePayload,
                    message: "Invalid frame payload",
                    cause: nil,
                    errorCode: .frameError,
                    location: .here()
                )
            }

            // RFC 9114 § 7.1
            // Each frame's payload MUST contain exactly the fields identified in its description. A frame payload that contains additional bytes after the identified fields or a
            // frame payload that terminates before the end of the identified fields MUST be treated as a connection error of type H3_FRAME_ERROR.
            // In particular, redundant length encodings MUST be verified to be self-consistent; see Section 10.8.
            // RFC 9114 § 10.8
            // Several protocol elements contain nested length elements, typically in the form of frames with an explicit length containing variable-length integers.
            // This could pose a security risk to an incautious implementer. An implementation MUST ensure that the length of a frame exactly matches the length of the fields it contains.

            // So we need to make sure there's no bytes left within the slice after the frame was parsed.

            guard payload.readableBytes == 0 else {
                throw HTTP3Error(
                    code: .invalidFramePayload,
                    message: "Frame length longer than payload",
                    cause: nil,
                    errorCode: .frameError,
                    location: .here()
                )
            }
            return .returnFrame(frame)
        }
    }
}

extension ByteBuffer {
    /// Read a HTTP/3 frame given a buffer containing only the payload. The type and length should have already been parsed out and passed in.
    /// `self` should be the payload, already sliced to the right length.
    /// - Returns: The frame, or nil if there aren't enough bytes.
    /// - Throws: If a frame is malformed in a specific way, e.g. a setting identifier is forbidden.
    fileprivate mutating func readHTTP3Frame(type: HTTP3FrameType) throws(HTTP3Error) -> HTTP3PartialFrameOrUnknown? {
        switch type {
        case .data:
            fatalError("Implementation error, this function should not be used to read a whole data frame.")
        case .headers:
            guard let fieldSection = try self.readFieldSectionWithHTTP3Error() else {
                return nil
            }
            return .known(.headers(.init(fieldSection: fieldSection)))
        case .cancelPush:
            guard let pushID = self.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
                return nil
            }

            return .known(.cancelPush(.init(rawValue: pushID)))
        case .settings:
            let settings = try self.readHTTP3Settings()
            return .known(.settings(settings))
        case .pushPromise:
            guard let pushID = self.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
                return nil
            }
            guard let fieldSection = try self.readFieldSectionWithHTTP3Error() else {
                return nil
            }
            return .known(.pushPromise(.init(pushID: .init(rawValue: pushID), fieldSection: fieldSection)))
        case .goaway:
            guard let id = self.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
                return nil
            }

            return .known(.goaway(.init(rawValue: id)))
        case .maxPushID:
            guard let pushID = self.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
                return nil
            }
            return .known(.maxPushID(.init(rawValue: pushID)))
        case .unknown:
            // We want to skip the payload for unknown types
            self.moveReaderIndex(forwardBy: self.readableBytes)
            return .unknown
        }
    }

    private mutating func readFieldSectionWithHTTP3Error() throws(HTTP3Error) -> FieldSection? {
        do {
            return try self.readFieldSection()
        } catch {
            switch error {
            case .unrepresentable:
                throw HTTP3Error(
                    code: .integerTooLarge,
                    message: "Integer is too large",
                    cause: error,
                    errorCode: .generalProtocolError,
                    location: .here()
                )
            }
        }
    }
}

package enum HTTP3PartialFrameOrUnknown: Hashable {
    case known(HTTP3PartialFrame)
    case unknown
}

extension HTTP3FrameType {
    fileprivate var maximumAcceptableLength: Int {
        switch self {
        case .data:
            fatalError("Implementation error, a data frame shouldn't get here")
        case .headers, .pushPromise:
            // This limit is currently arbitrary, Int32.max is just a convenient number to use because it always fit in an Int.
            return Int(Int32.max)
        case .cancelPush, .goaway, .maxPushID:
            // These frames hold a single integer to refer to a push or a stream or something.
            // A QUIC-encoded integer can be up to 8 bytes long.
            return 8
        case .settings:
            // Settings are identifier-value pairs and each pair is at most 16 bytes.
            // This allows for at least 64 settings.
            return 1024
        case .unknown:
            // This limit is arbitrary, the specification does not give us a limit.
            // 2^14 seems sensible because that's the default in http/2, and it's much higher than any currently defined http/3 frame.
            return 16384
        }
    }
}
