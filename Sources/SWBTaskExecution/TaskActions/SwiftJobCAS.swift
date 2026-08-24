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

package import SWBUtil

package enum SwiftJobCASMode: String, Sendable {
    case record
    case replay
    case readWrite = "read-write"

    package var reads: Bool { self != .record }
    package var writes: Bool { self != .replay }
}

package struct SwiftJobCASConfiguration: Sendable, Equatable {
    package static let rootVariable = "SWIFT_BUILD_JOB_CAS_ROOT"
    package static let modeVariable = "SWIFT_BUILD_JOB_CAS_MODE"

    package let root: Path
    package let mode: SwiftJobCASMode

    package init(root: Path, mode: SwiftJobCASMode) {
        self.root = root
        self.mode = mode
    }

    package static func parse(environment: [String: String]) -> Self? {
        guard let rawRoot = environment[rootVariable],
              !rawRoot.isEmpty,
              Path(rawRoot).isAbsolute,
              let rawMode = environment[modeVariable],
              let mode = SwiftJobCASMode(rawValue: rawMode) else {
            return nil
        }
        return .init(root: Path(rawRoot), mode: mode)
    }

    package static func removeControlVariables(from environment: inout [String: String]) {
        environment.removeValue(forKey: rootVariable)
        environment.removeValue(forKey: modeVariable)
    }
}

package struct SwiftJobCASIdentity: Sendable, Equatable {
    package static let schema = "swift-build-job-cas-identity-v4"
    package static let inputIdentityMode = "aggressive-primary-input-v1"

    package let key: String
    package let toolchainIdentity: String
    package let ruleInfoType: String
    package let moduleName: String
    package let commandLineDigest: String
    package let commandLine: [String]
    package let primaryInputDigests: [String]
    package let producerCompilerCacheKeys: [String]
    package let outputNames: [String]

    package init(
        toolchainIdentity: String,
        ruleInfoType: String,
        moduleName: String,
        primaryInputDigests: [String],
        producerCompilerCacheKeys: [String],
        commandLine: [String],
        outputNames: [String]
    ) {
        self.toolchainIdentity = toolchainIdentity
        self.ruleInfoType = ruleInfoType
        self.moduleName = moduleName
        self.primaryInputDigests = primaryInputDigests
        self.producerCompilerCacheKeys = producerCompilerCacheKeys
        self.outputNames = outputNames
        let normalizedCommandLine = Self.normalizedCommandLine(commandLine)
        self.commandLine = normalizedCommandLine
        self.commandLineDigest = Self.digest(fields: ["command-line-v2"] + normalizedCommandLine)
        self.key = Self.digest(fields: [
            Self.schema,
            toolchainIdentity,
            ruleInfoType,
            moduleName,
            commandLineDigest,
        ] + [Self.inputIdentityMode] + primaryInputDigests + ["outputs-v1"] + outputNames)
    }

    package static func digest(bytes: ByteString) -> String {
        let context = SHA256Context()
        context.add(bytes: bytes)
        return context.signature.asString
    }

    package static func normalizedCommandLine(_ commandLine: [String]) -> [String] {
        var normalized = commandLine
        for index in normalized.indices where normalized[index] == "-supplementary-output-file-map" {
            let valueIndex = normalized.index(after: index)
            if valueIndex < normalized.endIndex {
                normalized[valueIndex] = "<supplementary-output-file-map>"
            }
        }
        for index in normalized.indices where normalized[index] == "-clang-include-tree-filelist" {
            let valueIndex = normalized.index(after: index)
            if valueIndex < normalized.endIndex {
                normalized[valueIndex] = "<clang-include-tree-filelist>"
            }
        }
        return normalized
    }

    /// This intentionally experimental identity hashes only the files compiled as
    /// primaries by this frontend job. The compiler's cache keys are retained in
    /// the action for diagnostics, but are excluded because they currently change
    /// module-wide after a single source mutation.
    package static func primaryInputDigests(
        commandLine: [String],
        workingDirectory: Path? = nil,
        fs: any FSProxy
    ) throws -> [String]? {
        var inputs: [String] = []
        var index = commandLine.startIndex
        while index < commandLine.endIndex {
            guard commandLine[index] == "-primary-file" else {
                index = commandLine.index(after: index)
                continue
            }
            let valueIndex = commandLine.index(after: index)
            guard valueIndex < commandLine.endIndex else { return nil }
            let path = Path(commandLine[valueIndex])
            guard path.isAbsolute else { return nil }
            let readPath: Path
            if path.str.hasPrefix("/^src/"), let workingDirectory {
                readPath = workingDirectory.join(String(path.str.dropFirst("/^src/".count)))
            } else {
                readPath = path
            }
            let contents = try fs.read(readPath)
            inputs.append(path.str + "=" + digest(bytes: contents))
            index = commandLine.index(after: valueIndex)
        }
        return inputs.isEmpty ? nil : inputs
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

package enum SwiftJobCASReplayOutcome: Sendable, Equatable {
    case hit(outputCount: Int, outputBytes: UInt64)
    case miss
    case invalid(String)
}

package struct SwiftJobCASRecordResult: Sendable, Equatable {
    package let outputCount: Int
    package let outputBytes: UInt64
    package let newBlobCount: Int
    package let actionCreated: Bool
}

package struct SwiftJobCASEvent: Codable, Sendable, Equatable {
    package static let schema = "swift-build-job-cas-event-v1"

    package let schema: String
    package let timestampUnixNS: UInt64
    package let processID: Int32
    package let jobKey: String
    package let operation: String
    package let outcome: String
    package let durationNS: UInt64
    package let outputCount: Int?
    package let outputBytes: UInt64?
    package let detail: String?

    package init(
        jobKey: String,
        operation: String,
        outcome: String,
        durationNS: UInt64,
        outputCount: Int? = nil,
        outputBytes: UInt64? = nil,
        detail: String? = nil
    ) {
        self.schema = Self.schema
        self.timestampUnixNS = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        self.processID = ProcessInfo.processInfo.processIdentifier
        self.jobKey = jobKey
        self.operation = operation
        self.outcome = outcome
        self.durationNS = durationNS
        self.outputCount = outputCount
        self.outputBytes = outputBytes
        self.detail = detail
    }
}

package struct SwiftJobCASStore: Sendable {
    private struct Output: Codable, Equatable {
        let ordinal: Int
        let name: String
        let blob: String
        let size: UInt64
    }

    private struct Action: Codable, Equatable {
        static let schema = "swift-build-job-cas-action-v5"

        let schema: String
        let jobKey: String
        let toolchainIdentity: String
        let ruleInfoType: String
        let moduleName: String
        let commandLineDigest: String
        let commandLine: [String]
        let inputIdentityMode: String
        let primaryInputDigests: [String]
        let producerCompilerCacheKeys: [String]
        let outputs: [Output]
    }

    package let root: Path

    package init(root: Path) {
        self.root = root
    }

    package func replay(
        identity: SwiftJobCASIdentity,
        destinations: [Path],
        fs: any FSProxy
    ) -> SwiftJobCASReplayOutcome {
        let actionPath = path(kind: "actions", digest: identity.key, suffix: ".json")
        guard fs.exists(actionPath) else { return .miss }

        do {
            let action = try decode(Action.self, from: fs.read(actionPath))
            guard action.schema == Action.schema,
                  action.jobKey == identity.key,
                  action.toolchainIdentity == identity.toolchainIdentity,
                  action.ruleInfoType == identity.ruleInfoType,
                  action.moduleName == identity.moduleName,
                  action.commandLineDigest == identity.commandLineDigest,
                  action.commandLine == identity.commandLine,
                  action.inputIdentityMode == SwiftJobCASIdentity.inputIdentityMode,
                  action.primaryInputDigests == identity.primaryInputDigests,
                  action.outputs.count == destinations.count,
                  action.outputs.map(\.ordinal) == Array(destinations.indices),
                  action.outputs.map(\.name) == identity.outputNames else {
                return .invalid("action manifest does not match the planned job")
            }

            var materialized: [ByteString] = []
            materialized.reserveCapacity(action.outputs.count)
            var totalBytes: UInt64 = 0
            for output in action.outputs {
                let blobPath = path(kind: "blobs", digest: output.blob)
                guard fs.exists(blobPath) else {
                    return .invalid("referenced blob is absent")
                }
                let contents = try fs.read(blobPath)
                guard UInt64(contents.bytes.count) == output.size,
                      SwiftJobCASIdentity.digest(bytes: contents) == output.blob else {
                    return .invalid("referenced blob failed content verification")
                }
                totalBytes += output.size
                materialized.append(contents)
            }

            for (destination, contents) in zip(destinations, materialized) {
                try fs.createDirectory(destination.dirname, recursive: true)
                try fs.write(destination, contents: contents, atomically: true)
            }
            return .hit(outputCount: action.outputs.count, outputBytes: totalBytes)
        } catch {
            return .invalid(String(describing: error))
        }
    }

    package func record(
        identity: SwiftJobCASIdentity,
        outputs: [Path],
        fs: any FSProxy
    ) throws -> SwiftJobCASRecordResult {
        guard outputs.map(\.basename) == identity.outputNames else {
            throw StubError.error("job CAS output names do not match the identity")
        }

        let contents = try outputs.map { try fs.read($0) }
        var manifestOutputs: [Output] = []
        var totalBytes: UInt64 = 0
        var newBlobCount = 0
        manifestOutputs.reserveCapacity(outputs.count)

        for (ordinal, pair) in zip(outputs, contents).enumerated() {
            let (outputPath, bytes) = pair
            let digest = SwiftJobCASIdentity.digest(bytes: bytes)
            let byteCount = UInt64(bytes.bytes.count)
            let blobPath = path(kind: "blobs", digest: digest)
            try fs.createDirectory(blobPath.dirname, recursive: true)
            if !fs.exists(blobPath) {
                try fs.write(blobPath, contents: bytes, atomically: true)
                newBlobCount += 1
            }
            totalBytes += byteCount
            manifestOutputs.append(.init(
                ordinal: ordinal,
                name: outputPath.basename,
                blob: digest,
                size: byteCount
            ))
        }

        let action = Action(
            schema: Action.schema,
            jobKey: identity.key,
            toolchainIdentity: identity.toolchainIdentity,
            ruleInfoType: identity.ruleInfoType,
            moduleName: identity.moduleName,
            commandLineDigest: identity.commandLineDigest,
            commandLine: identity.commandLine,
            inputIdentityMode: SwiftJobCASIdentity.inputIdentityMode,
            primaryInputDigests: identity.primaryInputDigests,
            producerCompilerCacheKeys: identity.producerCompilerCacheKeys,
            outputs: manifestOutputs
        )
        let actionPath = path(kind: "actions", digest: identity.key, suffix: ".json")
        try fs.createDirectory(actionPath.dirname, recursive: true)
        let actionCreated: Bool
        if fs.exists(actionPath) {
            let existing = try decode(Action.self, from: fs.read(actionPath))
            guard existing.schema == action.schema,
                  existing.jobKey == action.jobKey,
                  existing.toolchainIdentity == action.toolchainIdentity,
                  existing.ruleInfoType == action.ruleInfoType,
                  existing.moduleName == action.moduleName,
                  existing.commandLineDigest == action.commandLineDigest,
                  existing.commandLine == action.commandLine,
                  existing.inputIdentityMode == action.inputIdentityMode,
                  existing.primaryInputDigests == action.primaryInputDigests,
                  existing.outputs == action.outputs else {
                throw StubError.error("job CAS action collision for \(identity.key)")
            }
            actionCreated = false
        } else {
            try fs.write(actionPath, contents: try encode(action), atomically: true)
            actionCreated = true
        }
        return .init(
            outputCount: manifestOutputs.count,
            outputBytes: totalBytes,
            newBlobCount: newBlobCount,
            actionCreated: actionCreated
        )
    }

    package func recordEvent(_ event: SwiftJobCASEvent, fs: any FSProxy) throws {
        let eventDirectory = root.join("events")
        try fs.createDirectory(eventDirectory, recursive: true)
        let filename = "\(event.timestampUnixNS)-\(event.processID)-\(UUID().uuidString.lowercased()).json"
        try fs.write(eventDirectory.join(filename), contents: try encode(event), atomically: true)
    }

    private func path(kind: String, digest: String, suffix: String = "") -> Path {
        let prefix = String(digest.prefix(2))
        return root.join(kind).join(prefix).join(digest + suffix)
    }

    private func encode<T: Encodable>(_ value: T) throws -> ByteString {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ByteString(try encoder.encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, from bytes: ByteString) throws -> T {
        try JSONDecoder().decode(type, from: Data(bytes.bytes))
    }
}

#endif
