//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT

import Foundation
import Testing

import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SwiftResidentFrontendProxyTests {
    @Test
    func selectsOnlyTheConfiguredPrimaryFrontendCommand() throws {
        let temporary = try NamedTemporaryDirectory()
        let source = temporary.path.join("Allowed.swift").str
        let evidence = temporary.path.join("evidence").str
        let socket = temporary.path.join("daemon.sock").str
        let configurationPath = temporary.path.join("configuration.json").str
        let configuration: [String: Any] = [
            "schema": SwiftResidentFrontendProxyConfiguration.schema,
            "enabled": true,
            "socket_path": socket,
            "proxy_path": "/usr/bin/true",
            "frontend_path": "/usr/bin/true",
            "evidence_root": evidence,
            "module_name": "Fixture",
            "allowed_primary_sources": [source],
            "timeout_milliseconds": 60_000,
        ]
        try JSONSerialization.data(
            withJSONObject: configuration, options: [.sortedKeys]
        ).write(to: URL(fileURLWithPath: configurationPath))

        var environment = [
            SwiftResidentFrontendProxyConfiguration.controlEnvironmentKey:
                configurationPath,
            "RETAINED": "yes",
        ]
        let maybeLoaded = try SwiftResidentFrontendProxyConfiguration.load(
            environment: environment
        )
        let loaded = try #require(maybeLoaded)
        let original = [
            "/toolchain/swift-frontend", "-frontend", "-c",
            "-primary-file", source,
            "-module-name", "Fixture",
            "-o", temporary.path.join("Allowed.o").str,
        ]
        let proxied = try #require(loaded.proxyCommand(for: original))
        #expect(proxied.prefix(9) == [
            "/usr/bin/true",
            "--socket", socket,
            "--frontend", "/usr/bin/true",
            "--evidence-root", evidence,
            "--timeout-ms", "60000",
        ])
        #expect(proxied[9] == "--")
        #expect(Array(proxied.dropFirst(10)) == original)
        #expect(loaded.proxyCommand(for: [
            "/toolchain/swift-frontend", "-frontend", "-c",
            "-primary-file", temporary.path.join("Unexpected.swift").str,
            "-module-name", "Fixture",
        ]) == nil)
        #expect(loaded.proxyCommand(for: [
            "/toolchain/swift-frontend", "-frontend", "-c",
            "-primary-file", source,
            "-module-name", "Other",
        ]) == nil)
        #expect(loaded.proxyCommand(for: [
            "/toolchain/swift-frontend", "-frontend", "-emit-module",
            "-primary-file", source,
            "-module-name", "Fixture",
        ]) == nil)

        SwiftResidentFrontendProxyConfiguration.removeControlVariable(
            from: &environment
        )
        #expect(environment == ["RETAINED": "yes"])
    }

    @Test
    func malformedConfigurationFailsClosed() throws {
        let temporary = try NamedTemporaryDirectory()
        let configurationPath = temporary.path.join("configuration.json").str
        try Data("{}".utf8).write(to: URL(fileURLWithPath: configurationPath))
        #expect(throws: (any Error).self) {
            try SwiftResidentFrontendProxyConfiguration.load(environment: [
                SwiftResidentFrontendProxyConfiguration.controlEnvironmentKey:
                    configurationPath,
            ])
        }
        #expect(try SwiftResidentFrontendProxyConfiguration.load(environment: [:]) == nil)
    }
}

#endif
