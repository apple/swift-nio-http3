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

@available(anyAppleOS 26, *)
extension QUICConfiguration {
    static func makeH3ServerConfig(
        serverName: String,
        publicKeyPath: String,
        privateKeyPath: String
    ) -> QUICConfiguration {
        QUICConfiguration.server(
            serverName: serverName,
            authenticationConfiguration: .rawPublicKeys(
                publicKeyFilePath: publicKeyPath,
                privateKeyFilePath: privateKeyPath
            ),
            applicationProtocols: ["h3"],
            // Disable idle timeout (zero = disabled per RFC 9000 §18.2) to avoid
            // races between idle timeout and stream error delivery in tests.
            maxIdleTimeout: .zero,
            initialMaxData: 10_000_000,
            initialMaxStreamDataBidiLocal: 1_000_000,
            initialMaxStreamDataBidiRemote: 1_000_000,
            initialMaxStreamDataUni: 1_000_000,
            initialMaxStreamsBidi: 100,
            initialMaxStreamsUni: 100
        )
    }

    static func makeH3ServerConfig(certPath: String, keyPath: String) -> QUICConfiguration {
        QUICConfiguration.server(
            serverName: "127.0.0.1",
            authenticationConfiguration: .x509Certificates(
                certificateChainFilePath: certPath,
                privateKeyFilePath: keyPath
            ),
            applicationProtocols: ["h3"],
            // Disable idle timeout (zero = disabled per RFC 9000 §18.2) to avoid
            // races between idle timeout and stream error delivery in tests.
            maxIdleTimeout: .zero,
            initialMaxData: 10_000_000,
            initialMaxStreamDataBidiLocal: 1_000_000,
            initialMaxStreamDataBidiRemote: 1_000_000,
            initialMaxStreamDataUni: 1_000_000,
            initialMaxStreamsBidi: 100,
            initialMaxStreamsUni: 100
        )
    }

    static func makeH3ClientConfig(trustedRootsPath: String) -> QUICConfiguration {
        let config = QUICConfiguration.client(
            verificationConfiguration: .x509Certificates(
                trustRootsFilePath: trustedRootsPath
            ),
            applicationProtocols: ["h3"],
            // Disable idle timeout (zero = disabled per RFC 9000 §18.2) to avoid
            // races between idle timeout and stream error delivery in tests.
            maxIdleTimeout: .zero,
            initialMaxData: 10_000_000,
            initialMaxStreamDataBidiLocal: 1_000_000,
            initialMaxStreamDataBidiRemote: 1_000_000,
            initialMaxStreamDataUni: 1_000_000,
            initialMaxStreamsBidi: 100,
            initialMaxStreamsUni: 100
        )
        return config
    }

    static func makeH3ClientConfig(publicKeyPath: String) -> QUICConfiguration {
        let config = QUICConfiguration.client(
            verificationConfiguration: .rawPublicKeys(
                publicKeyFilePath: publicKeyPath
            ),
            applicationProtocols: ["h3"],
            // Disable idle timeout (zero = disabled per RFC 9000 §18.2) to avoid
            // races between idle timeout and stream error delivery in tests.
            maxIdleTimeout: .zero,
            initialMaxData: 10_000_000,
            initialMaxStreamDataBidiLocal: 1_000_000,
            initialMaxStreamDataBidiRemote: 1_000_000,
            initialMaxStreamDataUni: 1_000_000,
            initialMaxStreamsBidi: 100,
            initialMaxStreamsUni: 100
        )
        return config
    }
}
