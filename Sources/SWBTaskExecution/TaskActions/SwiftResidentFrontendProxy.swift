//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SWBUtil

package struct SwiftResidentFrontendProxyConfiguration: Codable, Sendable, Equatable {
    package static let schema = "swift-build-resident-frontend-proxy-v2"
    package static let controlEnvironmentKey =
        "SWIFT_BUILD_U02_RESIDENT_FRONTEND_CONFIG"

    package let schema: String
    package let enabled: Bool
    package let socketPath: String
    package let proxyPath: String
    package let frontendPath: String
    package let moduleCachePath: String
    package let resourceDirectory: String
    package let evidenceRoot: String
    package let moduleName: String
    package let allowedPrimarySources: [String]
    package let timeoutMilliseconds: Int

    private enum CodingKeys: String, CodingKey {
        case schema
        case enabled
        case socketPath = "socket_path"
        case proxyPath = "proxy_path"
        case frontendPath = "frontend_path"
        case moduleCachePath = "module_cache_path"
        case resourceDirectory = "resource_directory"
        case evidenceRoot = "evidence_root"
        case moduleName = "module_name"
        case allowedPrimarySources = "allowed_primary_sources"
        case timeoutMilliseconds = "timeout_milliseconds"
    }

    package static func load(
        environment: [String: String]
    ) throws -> SwiftResidentFrontendProxyConfiguration? {
        guard let path = environment[controlEnvironmentKey] else { return nil }
        guard isAbsoluteCleanPath(path) else {
            throw StubError.error("Resident frontend configuration path is invalid.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        try configuration.validate()
        return configuration
    }

    package static func removeControlVariable(
        from environment: inout [String: String]
    ) {
        environment.removeValue(forKey: controlEnvironmentKey)
    }

    package func proxyCommand(for commandLine: [String]) -> [String]? {
        guard enabled,
              commandLine.count > 2,
              commandLine.contains("-frontend"),
              commandLine.contains("-c") || commandLine.contains("-emit-object"),
              Self.uniqueValue(after: "-module-name", in: commandLine) == moduleName,
              let primary = Self.uniqueValue(after: "-primary-file", in: commandLine),
              allowedPrimarySources.contains(primary)
        else { return nil }
        return [
            proxyPath,
            "--socket", socketPath,
            "--frontend", frontendPath,
            "--module-cache", moduleCachePath,
            "--resource-dir", resourceDirectory,
            "--evidence-root", evidenceRoot,
            "--timeout-ms", String(timeoutMilliseconds),
            "--",
        ] + commandLine
    }

    private func validate() throws {
        guard schema == Self.schema,
              Self.isAbsoluteCleanPath(socketPath),
              Self.isAbsoluteCleanPath(proxyPath),
              Self.isAbsoluteCleanPath(frontendPath),
              Self.isAbsoluteCleanPath(moduleCachePath),
              Self.isAbsoluteCleanPath(resourceDirectory),
              Self.isAbsoluteCleanPath(evidenceRoot),
              FileManager.default.isExecutableFile(atPath: proxyPath),
              FileManager.default.isExecutableFile(atPath: frontendPath),
              !moduleName.isEmpty, !moduleName.contains("\0"),
              !allowedPrimarySources.isEmpty,
              Set(allowedPrimarySources).count == allowedPrimarySources.count,
              allowedPrimarySources.allSatisfy(Self.isAbsoluteCleanPath),
              timeoutMilliseconds > 0, timeoutMilliseconds <= 3_600_000
        else {
            throw StubError.error("Resident frontend configuration is invalid.")
        }
    }

    private static func isAbsoluteCleanPath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0")
    }

    private static func uniqueValue(
        after option: String, in commandLine: [String]
    ) -> String? {
        let indices = commandLine.indices.filter {
            commandLine[$0] == option && commandLine.indices.contains($0 + 1)
        }
        guard indices.count == 1 else { return nil }
        return commandLine[indices[0] + 1]
    }
}
