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

public import NIOCore
@_spi(PackageInternal) public import QPACK

extension QPACKDecoderInstructionDecoder: NIOSingleStepByteToMessageDecoder {}
extension QPACKEncoderInstructionDecoder: NIOSingleStepByteToMessageDecoder {}

@_spi(PackageInternal)
extension QPACKDecoderInstructionEncoder: MessageToByteEncoder {}

@_spi(PackageInternal)
extension QPACKEncoderInstructionEncoder: MessageToByteEncoder {}
