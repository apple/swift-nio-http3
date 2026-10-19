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

import class Foundation.FileManager
import struct Foundation.UUID
import struct NIOQUIC.QUICConfiguration

@available(anyAppleOS 27, *)
extension QUICConfiguration {
    static func makeH3ServerConfig(
        serverName: String,
        publicKeyPath: String,
        privateKeyPath: String
    ) -> QUICConfiguration {
        var config = QUICConfiguration.forServer(
            serverName: serverName,
            authenticationConfiguration: .rawPublicKeys(
                publicKeyFilePath: publicKeyPath,
                privateKeyFilePath: privateKeyPath
            ),
            applicationProtocols: ["h3"]
        )
        // Disable idle timeout (zero = disabled per RFC 9000 §18.2) to avoid
        // races between idle timeout and stream error delivery in tests.
        config.maxIdleTimeout = .zero
        config.initialMaxData = 10_000_000
        config.initialMaxStreamDataBidiLocal = 1_000_000
        config.initialMaxStreamDataBidiRemote = 1_000_000
        config.initialMaxStreamDataUni = 1_000_000
        config.initialMaxStreamsBidi = 100
        config.initialMaxStreamsUni = 100
        return config
    }

    static func makeH3ServerConfig(certPath: String, keyPath: String) -> QUICConfiguration {
        var config = QUICConfiguration.forServer(
            serverName: "127.0.0.1",
            authenticationConfiguration: .x509Certificates(
                certificateChainFilePath: certPath,
                privateKeyFilePath: keyPath
            ),
            applicationProtocols: ["h3"]
        )
        // Disable idle timeout (zero = disabled per RFC 9000 §18.2) to avoid
        // races between idle timeout and stream error delivery in tests.
        config.maxIdleTimeout = .zero
        config.initialMaxData = 10_000_000
        config.initialMaxStreamDataBidiLocal = 1_000_000
        config.initialMaxStreamDataBidiRemote = 1_000_000
        config.initialMaxStreamDataUni = 1_000_000
        config.initialMaxStreamsBidi = 100
        config.initialMaxStreamsUni = 100
        return config
    }

    static func makeH3ClientConfig(trustedRootsPath: String) -> QUICConfiguration {
        var config = QUICConfiguration.forClient(
            verificationConfiguration: .x509Certificates(
                trustRootsFilePath: trustedRootsPath
            ),
            applicationProtocols: ["h3"]
        )
        // Disable idle timeout (zero = disabled per RFC 9000 §18.2) to avoid
        // races between idle timeout and stream error delivery in tests.
        config.maxIdleTimeout = .zero
        config.initialMaxData = 10_000_000
        config.initialMaxStreamDataBidiLocal = 1_000_000
        config.initialMaxStreamDataBidiRemote = 1_000_000
        config.initialMaxStreamDataUni = 1_000_000
        config.initialMaxStreamsBidi = 100
        config.initialMaxStreamsUni = 100
        return config
    }

    static func makeH3ClientConfig(publicKeyPath: String) -> QUICConfiguration {
        var config = QUICConfiguration.forClient(
            verificationConfiguration: .rawPublicKeys(
                publicKeyFilePath: publicKeyPath
            ),
            applicationProtocols: ["h3"]
        )
        // Disable idle timeout (zero = disabled per RFC 9000 §18.2) to avoid
        // races between idle timeout and stream error delivery in tests.
        config.maxIdleTimeout = .zero
        config.initialMaxData = 10_000_000
        config.initialMaxStreamDataBidiLocal = 1_000_000
        config.initialMaxStreamDataBidiRemote = 1_000_000
        config.initialMaxStreamDataUni = 1_000_000
        config.initialMaxStreamsBidi = 100
        config.initialMaxStreamsUni = 100
        return config
    }
}
