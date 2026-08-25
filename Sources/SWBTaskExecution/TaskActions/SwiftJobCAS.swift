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
import Synchronization

package import SWBUtil

package enum SwiftJobCASMode: String, Sendable {
    case record
    case replay
    case readWrite = "read-write"

    package var reads: Bool { self != .record }
    package var writes: Bool { self != .replay }
}

package enum SwiftJobCASVerification: String, Sendable {
    case verified
    case trustedLocal = "trusted-local"
}

package struct SwiftJobCASConfiguration: Sendable, Equatable {
    package static let rootVariable = "SWIFT_BUILD_JOB_CAS_ROOT"
    package static let modeVariable = "SWIFT_BUILD_JOB_CAS_MODE"
    package static let verificationVariable = "SWIFT_BUILD_JOB_CAS_VERIFICATION"

    package let root: Path
    package let mode: SwiftJobCASMode
    package let verification: SwiftJobCASVerification

    package init(
        root: Path,
        mode: SwiftJobCASMode,
        verification: SwiftJobCASVerification = .verified
    ) {
        self.root = root
        self.mode = mode
        self.verification = verification
    }

    package static func parse(environment: [String: String]) -> Self? {
        guard let rawRoot = environment[rootVariable],
              !rawRoot.isEmpty,
              Path(rawRoot).isAbsolute,
              let rawMode = environment[modeVariable],
              let mode = SwiftJobCASMode(rawValue: rawMode) else {
            return nil
        }
        let verification: SwiftJobCASVerification
        if let rawVerification = environment[verificationVariable] {
            guard let parsed = SwiftJobCASVerification(rawValue: rawVerification) else {
                return nil
            }
            verification = parsed
        } else {
            verification = .verified
        }
        return .init(root: Path(rawRoot), mode: mode, verification: verification)
    }

    package static func removeControlVariables(from environment: inout [String: String]) {
        environment.removeValue(forKey: rootVariable)
        environment.removeValue(forKey: modeVariable)
        environment.removeValue(forKey: verificationVariable)
    }
}

package struct SwiftJobCASIdentity: Sendable, Equatable {
    package static let schema = "swift-build-job-cas-identity-v4"
    package static let primaryOnlyInputIdentityMode = "aggressive-primary-input-v1"
    package static let dependencyAwareInputIdentityMode = "compiler-dependency-api-fingerprints-v1"

    package let key: String
    package let toolchainIdentity: String
    package let ruleInfoType: String
    package let moduleName: String
    package let commandLineDigest: String
    package let commandLine: [String]
    package let inputIdentityMode: String
    package let primaryInputDigests: [String]
    package let dependencyFingerprintDigests: [String]?
    package let producerCompilerCacheKeys: [String]
    package let outputNames: [String]

    package init(
        toolchainIdentity: String,
        ruleInfoType: String,
        moduleName: String,
        primaryInputDigests: [String],
        dependencyFingerprintDigests: [String]? = nil,
        producerCompilerCacheKeys: [String],
        commandLine: [String],
        outputNames: [String]
    ) {
        self.toolchainIdentity = toolchainIdentity
        self.ruleInfoType = ruleInfoType
        self.moduleName = moduleName
        self.primaryInputDigests = primaryInputDigests
        self.dependencyFingerprintDigests = dependencyFingerprintDigests
        let resolvedInputIdentityMode = dependencyFingerprintDigests == nil
            ? Self.primaryOnlyInputIdentityMode
            : Self.dependencyAwareInputIdentityMode
        self.inputIdentityMode = resolvedInputIdentityMode
        self.producerCompilerCacheKeys = producerCompilerCacheKeys
        self.outputNames = outputNames
        let normalizedCommandLine = Self.normalizedCommandLine(commandLine)
        self.commandLine = normalizedCommandLine
        self.commandLineDigest = Self.digest(fields: ["command-line-v2"] + normalizedCommandLine)
        var keyFields = [
            Self.schema,
            toolchainIdentity,
            ruleInfoType,
            moduleName,
            commandLineDigest,
            resolvedInputIdentityMode,
        ] + primaryInputDigests
        if let dependencyFingerprintDigests {
            keyFields += ["dependency-fingerprints-v1"] + dependencyFingerprintDigests.sorted()
        }
        keyFields += ["outputs-v1"] + outputNames
        self.key = Self.digest(fields: keyFields)
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
    package static let schema = "swift-build-job-cas-event-v2"

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
    package let verification: String?
    package let actionLookupDurationNS: UInt64?
    package let actionReadDurationNS: UInt64?
    package let actionValidationDurationNS: UInt64?
    package let blobReadDurationNS: UInt64?
    package let blobVerificationDurationNS: UInt64?
    package let outputPublicationDurationNS: UInt64?

    package init(
        jobKey: String,
        operation: String,
        outcome: String,
        durationNS: UInt64,
        outputCount: Int? = nil,
        outputBytes: UInt64? = nil,
        detail: String? = nil,
        verification: SwiftJobCASVerification? = nil,
        replayTimings: SwiftJobCASReplayTimings? = nil
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
        self.verification = verification?.rawValue
        self.actionLookupDurationNS = replayTimings?.actionLookupDurationNS
        self.actionReadDurationNS = replayTimings?.actionReadDurationNS
        self.actionValidationDurationNS = replayTimings?.actionValidationDurationNS
        self.blobReadDurationNS = replayTimings?.blobReadDurationNS
        self.blobVerificationDurationNS = replayTimings?.blobVerificationDurationNS
        self.outputPublicationDurationNS = replayTimings?.outputPublicationDurationNS
    }
}

package struct SwiftJobCASReplayTimings: Sendable, Equatable {
    package var actionLookupDurationNS: UInt64 = 0
    package var actionReadDurationNS: UInt64 = 0
    package var actionValidationDurationNS: UInt64 = 0
    package var blobReadDurationNS: UInt64 = 0
    package var blobVerificationDurationNS: UInt64 = 0
    package var outputPublicationDurationNS: UInt64 = 0

    package init() {}
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
        let dependencyFingerprintDigests: [String]?
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
        var timings = SwiftJobCASReplayTimings()
        return replay(
            identity: identity,
            destinations: destinations,
            verification: .verified,
            timings: &timings,
            fs: fs
        )
    }

    package func replay(
        identity: SwiftJobCASIdentity,
        destinations: [Path],
        verification: SwiftJobCASVerification,
        timings: inout SwiftJobCASReplayTimings,
        fs: any FSProxy
    ) -> SwiftJobCASReplayOutcome {
        let actionPath = path(kind: "actions", digest: identity.key, suffix: ".json")
        let lookupTimer = ElapsedTimer()
        let actionExists = fs.exists(actionPath)
        timings.actionLookupDurationNS = lookupTimer.elapsedTime().nanoseconds
        guard actionExists else { return .miss }

        do {
            let actionReadTimer = ElapsedTimer()
            let actionBytes = try fs.read(actionPath)
            timings.actionReadDurationNS = actionReadTimer.elapsedTime().nanoseconds
            let actionValidationTimer = ElapsedTimer()
            let action = try decode(Action.self, from: actionBytes)
            guard action.schema == Action.schema,
                  action.jobKey == identity.key,
                  action.toolchainIdentity == identity.toolchainIdentity,
                  action.ruleInfoType == identity.ruleInfoType,
                  action.moduleName == identity.moduleName,
                  action.commandLineDigest == identity.commandLineDigest,
                  action.commandLine == identity.commandLine,
                  action.inputIdentityMode == identity.inputIdentityMode,
                  action.primaryInputDigests == identity.primaryInputDigests,
                  action.dependencyFingerprintDigests == identity.dependencyFingerprintDigests,
                  action.outputs.count == destinations.count,
                  action.outputs.map(\.ordinal) == Array(destinations.indices),
                  action.outputs.map(\.name) == identity.outputNames else {
                return .invalid("action manifest does not match the planned job")
            }
            timings.actionValidationDurationNS = actionValidationTimer.elapsedTime().nanoseconds

            if verification == .trustedLocal {
                var blobs: [Path] = []
                blobs.reserveCapacity(action.outputs.count)
                let blobInspectionTimer = ElapsedTimer()
                for output in action.outputs {
                    let blobPath = path(kind: "blobs", digest: output.blob)
                    let info = try fs.getFileInfo(blobPath)
                    guard info.isFile, info.size >= 0, UInt64(info.size) == output.size else {
                        return .invalid("referenced blob is absent or has the wrong size")
                    }
                    blobs.append(blobPath)
                }
                timings.blobReadDurationNS = blobInspectionTimer.elapsedTime().nanoseconds

                let publicationTimer = ElapsedTimer()
                var published: [Path] = []
                do {
                    for (destination, blob) in zip(destinations, blobs) {
                        try fs.createDirectory(destination.dirname, recursive: true)
                        if fs.exists(destination) {
                            try fs.remove(destination)
                        }
                        try fs.copy(blob, to: destination)
                        published.append(destination)
                    }
                } catch {
                    for destination in published {
                        try? fs.remove(destination)
                    }
                    throw error
                }
                timings.outputPublicationDurationNS = publicationTimer.elapsedTime().nanoseconds
                return .hit(
                    outputCount: action.outputs.count,
                    outputBytes: action.outputs.reduce(0) { $0 + $1.size }
                )
            }

            var materialized: [ByteString] = []
            materialized.reserveCapacity(action.outputs.count)
            var totalBytes: UInt64 = 0
            for output in action.outputs {
                let blobPath = path(kind: "blobs", digest: output.blob)
                guard fs.exists(blobPath) else {
                    return .invalid("referenced blob is absent")
                }
                let blobReadTimer = ElapsedTimer()
                let contents = try fs.read(blobPath)
                timings.blobReadDurationNS += blobReadTimer.elapsedTime().nanoseconds
                let verificationTimer = ElapsedTimer()
                let valid = UInt64(contents.bytes.count) == output.size
                    && SwiftJobCASIdentity.digest(bytes: contents) == output.blob
                timings.blobVerificationDurationNS += verificationTimer.elapsedTime().nanoseconds
                guard valid else {
                    return .invalid("referenced blob failed content verification")
                }
                totalBytes += output.size
                materialized.append(contents)
            }

            let publicationTimer = ElapsedTimer()
            for (destination, contents) in zip(destinations, materialized) {
                try fs.createDirectory(destination.dirname, recursive: true)
                try fs.write(destination, contents: contents, atomically: true)
            }
            timings.outputPublicationDurationNS = publicationTimer.elapsedTime().nanoseconds
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
            inputIdentityMode: identity.inputIdentityMode,
            primaryInputDigests: identity.primaryInputDigests,
            dependencyFingerprintDigests: identity.dependencyFingerprintDigests,
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
                  existing.dependencyFingerprintDigests == action.dependencyFingerprintDigests,
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
        var bytes = try encode(event)
        bytes += ByteString(encodingAsUTF8: "\n")
        try Self.eventWriteLock.withLock {
            try fs.append(eventDirectory.join("events-v2.jsonl"), contents: bytes)
        }
    }

    private func path(kind: String, digest: String, suffix: String = "") -> Path {
        let prefix = String(digest.prefix(2))
        return root.join(kind).join(prefix).join(digest + suffix)
    }

    private static let eventWriteLock = SWBMutex<Void>(())

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
