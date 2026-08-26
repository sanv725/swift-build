//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT && SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT

import Foundation

package import SWBCore
package import SWBUtil

package enum SwiftDependencyProjectionCASMode: String, Sendable {
    case record
    case replay
    case readWrite = "read-write"

    package var reads: Bool { self != .record }
    package var writes: Bool { self != .replay }
}

package struct SwiftDependencyProjectionCASConfiguration: Sendable, Equatable {
    package static let rootVariable = "SWIFT_BUILD_DEPENDENCY_PROJECTION_CAS_ROOT"
    package static let modeVariable = "SWIFT_BUILD_DEPENDENCY_PROJECTION_CAS_MODE"

    package let root: Path
    package let mode: SwiftDependencyProjectionCASMode

    package init(root: Path, mode: SwiftDependencyProjectionCASMode) {
        self.root = root
        self.mode = mode
    }

    package static func parse(environment: [String: String]) -> Self? {
        guard let rawRoot = environment[rootVariable],
              !rawRoot.isEmpty,
              Path(rawRoot).isAbsolute,
              let rawMode = environment[modeVariable],
              let mode = SwiftDependencyProjectionCASMode(rawValue: rawMode) else {
            return nil
        }
        return .init(root: Path(rawRoot), mode: mode)
    }

    package static func removeControlVariables(from environment: inout [String: String]) {
        environment.removeValue(forKey: rootVariable)
        environment.removeValue(forKey: modeVariable)
    }
}

package struct SwiftDependencyProjectionCASIdentity: Sendable, Equatable {
    package static let schema = "swift-build-dependency-projection-cas-identity-v1"

    package let key: String
    package let sourceIdentity: String
    package let sourceDigest: String
    package let priorDependencyIdentity: String
    package let moduleStructureIdentity: String
    package let toolchainIdentity: String
    package let pathPolicyIdentity: String
    package let compilerVersion: String
    package let commandLineDigest: String
    package let commandLine: [String]

    package init(
        sourceIdentity: String,
        sourceDigest: String,
        previousManifest: SwiftDependencyModuleManifest,
        commandLine: [String],
        pathReplacements: [(physical: String, virtual: String)]
    ) {
        let normalized = Self.normalizedCommandLine(
            commandLine,
            pathReplacements: pathReplacements
        )
        let commandDigest = Self.digest(fields: ["command-line-v1"] + normalized)
        self.sourceIdentity = sourceIdentity
        self.sourceDigest = sourceDigest
        self.priorDependencyIdentity = previousManifest.dependencyIdentity
        self.moduleStructureIdentity = previousManifest.structureIdentity
        self.toolchainIdentity = previousManifest.toolchainIdentity
        self.pathPolicyIdentity = previousManifest.pathPolicyIdentity
        self.compilerVersion = previousManifest.compilerVersion
        self.commandLineDigest = commandDigest
        self.commandLine = normalized
        self.key = Self.digest(fields: [
            Self.schema,
            sourceIdentity,
            sourceDigest,
            previousManifest.dependencyIdentity,
            previousManifest.structureIdentity,
            previousManifest.toolchainIdentity,
            previousManifest.pathPolicyIdentity,
            previousManifest.compilerVersion,
            commandDigest,
        ])
    }

    package static func normalizedCommandLine(
        _ commandLine: [String],
        pathReplacements: [(physical: String, virtual: String)]
    ) -> [String] {
        let omittedPairs: Set<String> = [
            "-emit-reference-dependencies-path",
            "-index-store-path",
            "-cas-path",
        ]
        let orderedReplacements = pathReplacements.enumerated()
            .filter { !$0.element.physical.isEmpty }
            .sorted {
                if $0.element.physical.count != $1.element.physical.count {
                    return $0.element.physical.count > $1.element.physical.count
                }
                return $0.offset < $1.offset
            }
        var usedPhysicalPrefixes: Set<String> = []
        var uniqueReplacements: [(physical: String, virtual: String)] = []
        for (_, replacement) in orderedReplacements
        where usedPhysicalPrefixes.insert(replacement.physical).inserted {
            uniqueReplacements.append(replacement)
        }
        var result: [String] = []
        var index = 0
        while index < commandLine.count {
            let argument = commandLine[index]
            if omittedPairs.contains(argument), commandLine.indices.contains(index + 1) {
                result.append(argument)
                result.append("<\(argument.dropFirst())>")
                index += 2
                continue
            }
            if argument == "-vfsoverlay", commandLine.indices.contains(index + 1) {
                result.append(argument)
                result.append("<vfsoverlay>")
                index += 2
                continue
            }
            var normalized = argument
            for replacement in uniqueReplacements {
                normalized = normalized.replacingOccurrences(
                    of: replacement.physical,
                    with: replacement.virtual
                )
            }
            result.append(normalized)
            index += 1
        }
        return result
    }

    package static func digest(bytes: ByteString) -> String {
        let context = SHA256Context()
        context.add(bytes: bytes)
        return context.signature.asString
    }

    private static func digest(fields: [String]) -> String {
        let context = SHA256Context()
        for field in fields {
            let bytes = Array(field.utf8)
            context.add(number: UInt64(bytes.count))
            context.add(bytes: bytes)
        }
        return context.signature.asString
    }
}

package enum SwiftDependencyProjectionCASReplayOutcome: Sendable, Equatable {
    case hit(SwiftDependencyFingerprintProjection, bytes: UInt64)
    case miss
    case invalid(String)
}

package struct SwiftDependencyProjectionCASRecordResult: Sendable, Equatable {
    package let bytes: UInt64
    package let actionCreated: Bool
}

package struct SwiftDependencyProjectionCASStore: Sendable {
    private struct Action: Codable, Sendable, Equatable {
        static let schema = "swift-build-dependency-projection-cas-action-v1"

        let schema: String
        let key: String
        let sourceIdentity: String
        let sourceDigest: String
        let priorDependencyIdentity: String
        let moduleStructureIdentity: String
        let toolchainIdentity: String
        let pathPolicyIdentity: String
        let compilerVersion: String
        let commandLineDigest: String
        let commandLine: [String]
        let projection: SwiftDependencyFingerprintProjection
    }

    package let root: Path

    package init(root: Path) {
        self.root = root
    }

    package func replay(
        identity: SwiftDependencyProjectionCASIdentity,
        fs: any FSProxy
    ) -> SwiftDependencyProjectionCASReplayOutcome {
        let path = actionPath(identity.key)
        guard fs.exists(path) else { return .miss }
        do {
            let bytes = try fs.read(path)
            let action = try JSONDecoder().decode(Action.self, from: Data(bytes.bytes))
            guard action.schema == Action.schema,
                  action.key == identity.key,
                  action.sourceIdentity == identity.sourceIdentity,
                  action.sourceDigest == identity.sourceDigest,
                  action.priorDependencyIdentity == identity.priorDependencyIdentity,
                  action.moduleStructureIdentity == identity.moduleStructureIdentity,
                  action.toolchainIdentity == identity.toolchainIdentity,
                  action.pathPolicyIdentity == identity.pathPolicyIdentity,
                  action.compilerVersion == identity.compilerVersion,
                  action.commandLineDigest == identity.commandLineDigest,
                  action.commandLine == identity.commandLine,
                  action.projection.schema == SwiftDependencyFingerprintProjection.schema,
                  action.projection.compilerVersion == identity.compilerVersion,
                  action.projection.sourceFileInterfaceFingerprint != nil else {
                return .invalid("projection action does not match its identity")
            }
            return .hit(action.projection, bytes: UInt64(bytes.count))
        } catch {
            return .invalid(String(describing: error))
        }
    }

    package func record(
        identity: SwiftDependencyProjectionCASIdentity,
        projection: SwiftDependencyFingerprintProjection,
        fs: any FSProxy
    ) throws -> SwiftDependencyProjectionCASRecordResult {
        guard projection.schema == SwiftDependencyFingerprintProjection.schema,
              projection.compilerVersion == identity.compilerVersion,
              projection.sourceFileInterfaceFingerprint != nil else {
            throw StubError.error("projection CAS accepts only a valid compiler projection")
        }
        let action = Action(
            schema: Action.schema,
            key: identity.key,
            sourceIdentity: identity.sourceIdentity,
            sourceDigest: identity.sourceDigest,
            priorDependencyIdentity: identity.priorDependencyIdentity,
            moduleStructureIdentity: identity.moduleStructureIdentity,
            toolchainIdentity: identity.toolchainIdentity,
            pathPolicyIdentity: identity.pathPolicyIdentity,
            compilerVersion: identity.compilerVersion,
            commandLineDigest: identity.commandLineDigest,
            commandLine: identity.commandLine,
            projection: projection
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = ByteString(try encoder.encode(action))
        let path = actionPath(identity.key)
        try fs.createDirectory(path.dirname, recursive: true)
        let created: Bool
        if fs.exists(path) {
            let existing = try JSONDecoder().decode(
                Action.self,
                from: Data(try fs.read(path).bytes)
            )
            guard existing == action else {
                throw StubError.error("projection CAS action collision for \(identity.key)")
            }
            created = false
        } else {
            try fs.write(path, contents: encoded, atomically: true)
            created = true
        }
        return .init(bytes: UInt64(encoded.count), actionCreated: created)
    }

    private func actionPath(_ key: String) -> Path {
        root.join("actions").join(String(key.prefix(2))).join("\(key).json")
    }
}

#endif
