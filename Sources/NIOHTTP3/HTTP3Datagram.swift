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

internal import HTTP3
public import NIOCore
public import NIOQUICHelpers

public struct HTTP3Datagram: @unchecked Sendable {
    // Unchecked because this struct is backed by a class. Safe because it uses uniqueness checks.

    // A seemingly unnecessary class in a struct? Outrageous! Unfortunately, for efficient message
    // passing down NIO's channel pipeline, message types must be <= 24 bytes in size so that they
    // can fit into the inline storage of an existential container. Unfortunately as a "normal"
    // struct HTTP3Datagram would be 31 bytes (23 for the buffer, 8 for the stream ID) so it would
    // miss the optimisation and require boxing every time the datagram is wrapped in a NIOAny. By
    // using a backing class we still pay that cost but only once, on construction.
    private final class Storage {
        var streamID: QUICStreamID
        var payload: ByteBuffer

        init(streamID: QUICStreamID, data: ByteBuffer) {
            self.streamID = streamID
            self.payload = data
        }

        func copy() -> Storage {
            Storage(streamID: self.streamID, data: self.payload)
        }
    }

    /// The underlying heap storage for the struct.
    private var storage: Storage

    private mutating func copyIfNotUniquelyReferenced() {
        if !isKnownUniquelyReferenced(&self.storage) {
            self.storage = self.storage.copy()
        }
    }

    /// The ID of the stream that this datagram is associated with.
    ///
    /// - Note: this isn't the _quarter stream ID_ as outlined in RFC 9297.
    public var streamID: QUICStreamID {
        get { self.storage.streamID }
        set {
            self.copyIfNotUniquelyReferenced()
            self.storage.streamID = newValue
        }
    }

    /// The payload of the datagram.
    public var payload: ByteBuffer {
        get { self.storage.payload }
        set {
            self.copyIfNotUniquelyReferenced()
            self.storage.payload = newValue
        }
    }

    /// Creates a new datagram.
    ///
    /// - Parameters:
    ///   - streamID: The ID of the stream this datagram is associated with.
    ///   - data: The payload of the datagram.
    public init(streamID: QUICStreamID, data: ByteBuffer) {
        self.storage = Storage(streamID: streamID, data: data)
    }
}

extension HTTP3Datagram {
    // RFC 9297 § 2.1: "the largest legal value of the Quarter Stream ID field is 2^60-1"
    static var largestValidQuarterStreamID: UInt64 {
        (1 << 60) - 1
    }
}

extension ByteBuffer {
    mutating func parseDatagram() throws(HTTP3Error) -> HTTP3Datagram {
        guard let quarterStreamID = self.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
            // From RFC 9297 § 2.1:
            //
            // > Receipt of a QUIC DATAGRAM frame whose payload is too short to allow parsing the
            // > Quarter Stream ID field MUST be treated as an HTTP/3 connection error of
            // > type H3_DATAGRAM_ERROR (0x33).
            throw HTTP3Error(
                code: .remoteConnectionError,
                message: "Datagram too short to parse",
                cause: nil,
                errorCode: .datagramError,
                location: .here()
            )
        }

        guard quarterStreamID <= HTTP3Datagram.largestValidQuarterStreamID else {
            // From RFC 9297 § 2.1:
            //
            // > Receipt of an HTTP/3 Datagram that includes a larger value [than the largest valid
            // > quarter stream ID] MUST be treated as an > HTTP/3 connection error of
            // > type H3_DATAGRAM_ERROR (0x33).
            throw HTTP3Error(
                code: .remoteConnectionError,
                message: "Invalid quarter stream ID",
                cause: nil,
                errorCode: .datagramError,
                location: .here()
            )
        }

        // This operation can't overflow: the quarter stream ID is small enough (verified above)
        // to be multiplied by four without overflowing.
        let rawStreamID = quarterStreamID &* 4

        // TODO: QUICStreamID(rawValue:) preconditions on the size of the raw valaue; it'd be nice
        // to have a variant which avoids this given we've validated it here.
        let streamID = QUICStreamID(rawValue: rawStreamID)

        let data = self.readSlice(length: self.readableBytes)!
        return HTTP3Datagram(streamID: streamID, data: data)
    }

    @discardableResult
    mutating func writeDatagram(_ datagram: HTTP3Datagram) -> Int {
        // Assume largest sized integer for stream ID. Capacity is rounded up to the nearest power
        // of two so using the largest size won't make any difference in the vast majority of cases.
        self.reserveCapacity(minimumWritableBytes: 8 + datagram.payload.readableBytes)

        var bytesWritten = 0
        let quarterStreamID = datagram.streamID.rawValue / 4

        // The HTTP3 connection handler should reject invalid datagrams before encoding them, add
        // a defensive check.
        assert(
            quarterStreamID * 4 == datagram.streamID.rawValue,
            "Stream ID must be for a client initiated bidirectional stream"
        )

        bytesWritten += self.writeEncodedInteger(quarterStreamID, strategy: .quic)
        bytesWritten += self.writeImmutableBuffer(datagram.payload)
        return bytesWritten
    }
}
