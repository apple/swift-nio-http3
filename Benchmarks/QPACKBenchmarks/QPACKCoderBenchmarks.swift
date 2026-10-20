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

import Benchmark
import HTTPTypes
import NIOCore
import NIOQUICHelpers
@_spi(PackageInternal) import QPACK

/// A typical small response, as a server sends it for most requests.
private let responseHeaders: [HTTPField] = [
    HTTPField(name: .init(parsed: ":status")!, value: "200"),
    HTTPField(name: .init(parsed: "content-type")!, value: "text/html; charset=utf-8"),
    HTTPField(name: .init(parsed: "content-length")!, value: "1234"),
    HTTPField(name: .init(parsed: "date")!, value: "Fri, 16 Oct 2026 10:00:00 GMT"),
    HTTPField(name: .init(parsed: "server")!, value: "swift-nio-http3"),
    HTTPField(name: .init(parsed: "cache-control")!, value: "max-age=604800"),
]

private struct DiscardingEncoderStream: QPACKOutboundEncoderStream {
    mutating func sendInstructions(_ instructions: some Collection<QPACKEncoderInstruction>) {
        blackHole(instructions.count)
    }
}

private struct DiscardingDecoderStream: QPACKOutboundDecoderStream {
    mutating func sendInstruction(_ instruction: QPACKDecoderInstruction) {}
    mutating func sendInstructions(_ instruction: some Collection<QPACKDecoderInstruction>) {}
}

private struct NoConnection: QPACKConnectionDelegate {
    func makeOutboundEncoderStream() {}
}

private struct NoDecodeReceiver: QPACKDecodeReceiver {
    func decodeResult(_ result: Result<[HTTPField], QPACKError>) {}
}

private typealias BenchmarkCoder = QPACKCoder<
    DiscardingEncoderStream, DiscardingDecoderStream, NoConnection, NoDecodeReceiver
>

extension BenchmarkCoder {
    /// A coder which never got an encoder stream, so it encodes with the static table only.
    fileprivate static func makeStaticCoder() -> BenchmarkCoder {
        BenchmarkCoder(
            encoderMaxTableSize: 0,
            decoderMaxTableSize: 0,
            decoderMaxBlockedStreams: 0,
            errorDelegate: NoConnection()
        )
    }

    /// A coder which uses a 4 KiB dynamic table.
    fileprivate static func makeDynamicCoder() throws -> BenchmarkCoder {
        let coder = BenchmarkCoder(
            encoderMaxTableSize: 4096,
            decoderMaxTableSize: 0,
            decoderMaxBlockedStreams: 0,
            errorDelegate: NoConnection()
        )
        try coder.receivedRemoteSettings(maxQueueSize: 100, peersDynamicTableSize: 4096)
        coder.outboundEncoderStreamReady(DiscardingEncoderStream())
        return coder
    }

    /// QPACK encodes `fields` with `coder` and writes the field section into `buffer`, the bytes of a HEADERS frame's
    /// payload.
    fileprivate func encodeFields(
        _ fields: [HTTPField],
        streamID: QUICStreamID,
        into buffer: inout ByteBuffer
    ) {
        let fieldSection = self.encodeHeaders(fields, streamID: streamID)
        buffer.writeFieldSectionPrefix(fieldSection.prefix)
        for line in fieldSection.lines {
            buffer.writeFieldLine(line, preferHuffmanEncoding: true)
        }
    }
}

private func coderEncodeBenchmark(_ name: String, fields: [HTTPField], dynamic: Bool) {
    Benchmark(
        name,
        configuration: .init(
            metrics: [.mallocCountTotal, .instructions, .wallClock],
            units: [.instructions: .count],
            scalingFactor: .kilo
        )
    ) { benchmark in
        let coder = dynamic ? try BenchmarkCoder.makeDynamicCoder() : BenchmarkCoder.makeStaticCoder()
        let streamID = QUICStreamID(rawValue: 0)
        var buffer = ByteBuffer()
        buffer.reserveCapacity(1024)

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            buffer.clear()
            coder.encodeFields(fields, streamID: streamID, into: &buffer)
            if dynamic {
                // Acknowledge the section, so the encoder stays in its steady state: every entry known received,
                // and nothing blocked.
                try coder.receivedIncomingDecoderInstruction(.sectionAcknowledgement(streamID: streamID))
            }
            blackHole(buffer)
        }
    }
}

/// Encodes field sections end to end through the ``QPACKCoder``, from `[HTTPField]` to bytes.
func qpackCoderBenchmarks() {
    coderEncodeBenchmark("QPACKCoderEncode_Static_BrowserGET", fields: requestHeaders, dynamic: false)
    coderEncodeBenchmark("QPACKCoderEncode_Static_Response", fields: responseHeaders, dynamic: false)
    coderEncodeBenchmark("QPACKCoderEncode_Dynamic_BrowserGET", fields: requestHeaders, dynamic: true)
    coderEncodeBenchmark("QPACKCoderEncode_Dynamic_Response", fields: responseHeaders, dynamic: true)
}
