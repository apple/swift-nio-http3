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
import NIOCore
import NIOQUICHelpers
@_spi(PackageInternal) import QPACK
import Testing

struct EndToEndTests {
    @Test
    func endToEnd() throws {
        var decoder = QPACKDecoder(dynamicTableMaxCapacity: 1024)

        var stream0 = ByteBuffer()
        var stream4 = ByteBuffer()
        var stream8 = ByteBuffer()
        var encoderBytes = ByteBuffer()

        /// Example RFC 9204 Appendix B.1. Literal Field Line with Name Reference.
        stream0.writeBytes([
            0x0, 0x0,  // Required Insert Count = 0, Base = 0
            // Literal Field Line with Name Reference, Static Table, Index=1 (:path=/index.html)
            0x51, 0x0b, 0x2f, 0x69, 0x6e, 0x64, 0x65, 0x78, 0x2e, 0x68, 0x74, 0x6d, 0x6c,
        ])

        let firstDecodeResult = try decoder.decodeFieldSection(streamBytes: &stream0, streamID: 0).unwrap()
        let firstDecoded = firstDecodeResult?.0
        #expect(firstDecoded?.count == 1)
        #expect(firstDecoded?.first?.name.canonicalName == ":path")
        #expect(firstDecoded?.first?.value == "/index.html")
        #expect(firstDecodeResult?.1 == nil)  // No instructions, because it's a literal

        /// Example RFC 9204 Appendix B.2. Dynamic Table.
        encoderBytes.writeBytes([
            0x3f, 0xbd, 0x01,  // Set Dynamic Table Capacity=220
            0xc0, 0x0f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78,  // Insert With Name Reference
            0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f,  // Static Table, Index=0
            0x6d,  //  (:authority=www.example.com)
            0xc1, 0x0c, 0x2f, 0x73, 0x61, 0x6d, 0x70, 0x6c,  // Insert With Name Reference
            0x65, 0x2f, 0x70, 0x61, 0x74, 0x68,  // Static Table, Index=1 (:path=/sample/path)
        ])

        while let instruction = try encoderBytes.readQPACKEncoderInstruction() {
            _ = try decoder.processInstruction(instruction)
        }

        stream4.writeBytes([
            // Required Insert Count = 2, Base = 0
            0x03, 0x81,
            // Indexed Field Line With Post-Base Index, Absolute Index = Base(0) + Index(0) = 0 (:authority=www.example.com)
            0x10,
            // Indexed Field Line With Post-Base Index, Absolute Index = Base(0) + Index(1) = 1 (:path=/sample/path)
            0x11,
        ])

        let secondDecodeResult = try decoder.decodeFieldSection(streamBytes: &stream4, streamID: 4).unwrap()

        guard let secondDecoded = secondDecodeResult?.0 else {
            Issue.record("Unexpected nil")
            return
        }
        #expect(secondDecoded.count == 2)
        #expect(secondDecoded[0].name.canonicalName == ":authority")
        #expect(secondDecoded[0].value == "www.example.com")
        #expect(secondDecoded[1].name.canonicalName == ":path")
        #expect(secondDecoded[1].value == "/sample/path")
        #expect(secondDecodeResult?.1 == .sectionAcknowledgement(streamID: 4))

        /// Example RFC 9204 Appendix B.3. Speculative Insert.
        encoderBytes.writeBytes([
            0x4a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d,  // Insert With Literal Name
            0x6b, 0x65, 0x79, 0x0c, 0x63, 0x75, 0x73, 0x74,  // (custom-key=custom-value)
            0x6f, 0x6d, 0x2d, 0x76, 0x61, 0x6c, 0x75, 0x65,
        ])

        var decoderInstructions1 = [QPACKDecoderInstruction?]()
        while let instruction = try encoderBytes.readQPACKEncoderInstruction() {
            decoderInstructions1.append(try decoder.processInstruction(instruction))
        }

        #expect(decoderInstructions1 == [.insertCountIncrement(increment: 1)])

        /// Example RFC 9204 Appendix B.4. Duplicate Instruction, Stream Cancellation.
        encoderBytes.writeBytes([
            0x02  // Duplicate (Relative Index = 2) Absolute Index = Insert Count(3) - Index(2) - 1 = 0
        ])
        // We delay sending the above bytes

        stream8.writeBytes([
            // Required Insert Count = 4, Base = 4
            0x05, 0x00,
            // Indexed Field Line, Dynamic Table Absolute Index = Base(4) - Index(0) - 1 = 3 | (:authority=www.example.com)
            0x80,
            // Indexed Field Line, Static Table Index = 1 | (:path=/)
            0xc1,
            // Indexed Field Line, Dynamic Table Absolute Index = Base(4) - Index(1) - 1 = 2 | (custom-key=custom-value)
            0x81,
        ])
        let thirdDecodeResult = try decoder.decodeFieldSection(streamBytes: &stream8, streamID: 8)
        guard case .missingInsertCount = thirdDecodeResult else {
            Issue.record("Unexpected result")
            return
        }

        let decoderInstructions2 = decoder.cancelStream(streamID: 8)
        #expect(decoderInstructions2 == .streamCancellation(streamID: 8))

        /// Example RFC 9204 Appendix B.5. Dynamic Table Insert, Eviction.
        encoderBytes.writeBytes([
            // Insert With Name Reference
            0x81, 0x0d, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d,
            //  Dynamic Table, Relative Index = 1 | Absolute Index = Insert Count(4) - Index(1) - 1 = 2 (custom-key=custom-value2)
            0x2d, 0x76, 0x61, 0x6c, 0x75, 0x65, 0x32,
        ])

        var decoderInstructions3 = [QPACKDecoderInstruction]()
        while let instruction = try encoderBytes.readQPACKEncoderInstruction() {
            if let decoderInstruction = try decoder.processInstruction(instruction) {
                decoderInstructions3.append(decoderInstruction)
            }
        }

        // one ack for the previous instruction still queued from before, and one for this insert
        #expect(decoderInstructions3 == [.insertCountIncrement(increment: 1), .insertCountIncrement(increment: 1)])
    }
}

extension QPACKDecoder {
    fileprivate mutating func decodeFieldSection(
        streamBytes: inout ByteBuffer,
        streamID: QUICStreamID
    ) throws -> QPACKFullDecodeResult {
        guard let fieldSection = try streamBytes.readFieldSection(),
            let prefix = self.decodeFieldSectionPrefix(fieldSection.prefix)
        else {
            return .error(QPACKDecoderError.invalidFieldSection)
        }
        return self.decodeFieldSection(prefix: prefix, lines: fieldSection.lines, streamID: streamID)
    }
}
