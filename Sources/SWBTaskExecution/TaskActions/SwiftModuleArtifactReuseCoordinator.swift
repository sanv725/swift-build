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

package struct SwiftModuleArtifactReuseConfiguration: Codable, Sendable, Equatable {
    package static let schema = "swift-build-module-artifact-reuse-configuration-v1"
    package static let pathVariable = "SWIFT_BUILD_OPT_MODULE_REUSE_CONFIG"

    package struct Artifact: Codable, Sendable, Equatable {
        package let path: String
        package let byteCount: Int64
        package let sha256: String

        package init(path: String, byteCount: Int64, sha256: String) {
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    package let schema: String
    package let moduleName: String
    package let changedSourcePath: String
    package let candidateSourceSHA256: String
    package let expectedInterfaceFingerprint: String
    package let emitModuleArtifacts: [Artifact]
    package let waitTimeoutMilliseconds: Int
    package let compileStartGraceMilliseconds: Int?

    package init(
        moduleName: String,
        changedSourcePath: String,
        candidateSourceSHA256: String,
        expectedInterfaceFingerprint: String,
        emitModuleArtifacts: [Artifact],
        waitTimeoutMilliseconds: Int = 30_000,
        compileStartGraceMilliseconds: Int = 25
    ) {
        self.schema = Self.schema
        self.moduleName = moduleName
        self.changedSourcePath = changedSourcePath
        self.candidateSourceSHA256 = candidateSourceSHA256
        self.expectedInterfaceFingerprint = expectedInterfaceFingerprint
        self.emitModuleArtifacts = emitModuleArtifacts
        self.waitTimeoutMilliseconds = waitTimeoutMilliseconds
        self.compileStartGraceMilliseconds = compileStartGraceMilliseconds
    }

    package static func path(environment: [String: String]) throws -> Path? {
        guard let rawPath = environment[pathVariable], !rawPath.isEmpty else { return nil }
        let path = Path(rawPath)
        guard path.isAbsolute else {
            throw StubError.error("\(pathVariable) must be an absolute path.")
        }
        return path
    }

    package static func removeControlVariable(from environment: inout [String: String]) {
        environment.removeValue(forKey: pathVariable)
    }
}

package enum SwiftModuleArtifactReuseDecision: Sendable, Equatable {
    case reuse(outputCount: Int, outputBytes: Int64, waitedNS: UInt64)
    case appleFallback(reason: String, waitedNS: UInt64)
    case cancelled(waitedNS: UInt64)
}

package final class SwiftModuleArtifactReuseCoordinator: @unchecked Sendable {
    private enum Observation: Sendable, Equatable {
        case waiting
        case compileRunning
        case fingerprint(String)
        case aborted(String)
    }

    private let configuration: SwiftModuleArtifactReuseConfiguration
    private let fs: any FSProxy
    private let observation = Mutex<Observation>(.waiting)

    package init(configurationPath: Path, fs: any FSProxy) throws {
        let bytes = try fs.read(configurationPath)
        let configuration = try JSONDecoder().decode(
            SwiftModuleArtifactReuseConfiguration.self,
            from: Data(bytes.bytes)
        )
        guard configuration.schema == SwiftModuleArtifactReuseConfiguration.schema else {
            throw StubError.error("Unsupported Swift module artifact reuse schema.")
        }
        guard !configuration.moduleName.isEmpty,
              Path(configuration.changedSourcePath).isAbsolute,
              !configuration.candidateSourceSHA256.isEmpty,
              !configuration.expectedInterfaceFingerprint.isEmpty,
              (1...120_000).contains(configuration.waitTimeoutMilliseconds),
              (1...1_000).contains(configuration.compileStartGraceMilliseconds ?? 25),
              !configuration.emitModuleArtifacts.isEmpty else {
            throw StubError.error("Invalid Swift module artifact reuse configuration.")
        }
        let artifactPaths = configuration.emitModuleArtifacts.map { Path($0.path) }
        guard artifactPaths.allSatisfy(\.isAbsolute),
              Set(artifactPaths).count == artifactPaths.count,
              configuration.emitModuleArtifacts.allSatisfy({
                  $0.byteCount >= 0 && !$0.sha256.isEmpty
              }) else {
            throw StubError.error("Invalid Swift module artifact reuse manifest.")
        }
        self.configuration = configuration
        self.fs = fs
    }

    package var moduleName: String { configuration.moduleName }

    package func accepts(primaryPath: Path, moduleName: String) -> Bool {
        moduleName == configuration.moduleName
            && primaryPath == Path(configuration.changedSourcePath)
    }

    @discardableResult
    package func beginChangedCompile(primaryPath: Path, moduleName: String) -> Bool {
        guard accepts(primaryPath: primaryPath, moduleName: moduleName) else { return false }
        return observation.withLock { current in
            guard current == .waiting else { return false }
            current = .compileRunning
            return true
        }
    }

    @discardableResult
    package func publishInterfaceFingerprint(
        _ fingerprint: String,
        primaryPath: Path,
        moduleName: String
    ) -> Bool {
        guard accepts(primaryPath: primaryPath, moduleName: moduleName) else { return false }
        return observation.withLock { current in
            guard current == .waiting || current == .compileRunning else { return false }
            current = .fingerprint(fingerprint)
            return true
        }
    }

    package func abortChangedCompile(
        reason: String,
        primaryPath: Path,
        moduleName: String
    ) {
        guard accepts(primaryPath: primaryPath, moduleName: moduleName) else { return }
        observation.withLock { current in
            guard current == .waiting || current == .compileRunning else { return }
            current = .aborted(reason)
        }
    }

    package func decision(
        moduleName: String,
        plannedOutputs: [Path],
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> SwiftModuleArtifactReuseDecision {
        let timer = ElapsedTimer()
        guard moduleName == configuration.moduleName else {
            return .appleFallback(reason: "module_mismatch", waitedNS: timer.elapsedTime().nanoseconds)
        }
        let configuredOutputs = configuration.emitModuleArtifacts.map { Path($0.path) }
        guard plannedOutputs.count == configuredOutputs.count,
              Set(plannedOutputs) == Set(configuredOutputs) else {
            return .appleFallback(reason: "output_set_mismatch", waitedNS: timer.elapsedTime().nanoseconds)
        }

        let timeoutNS = UInt64(configuration.waitTimeoutMilliseconds) * 1_000_000
        let startGraceNS = UInt64(
            configuration.compileStartGraceMilliseconds ?? 25
        ) * 1_000_000
        while true {
            if isCancelled() || _Concurrency.Task<Never, Never>.isCancelled {
                return .cancelled(waitedNS: timer.elapsedTime().nanoseconds)
            }
            switch observation.withLock({ $0 }) {
            case .waiting:
                let elapsedNS = timer.elapsedTime().nanoseconds
                if elapsedNS >= startGraceNS {
                    let stoppedWaiting = observation.withLock { current in
                        guard current == .waiting else { return false }
                        current = .aborted("changed_compile_not_started")
                        return true
                    }
                    if stoppedWaiting {
                        return .appleFallback(
                            reason: "changed_compile_not_started", waitedNS: elapsedNS
                        )
                    }
                }
                do {
                    try await _Concurrency.Task<Never, Never>.sleep(nanoseconds: 1_000_000)
                } catch {
                    return .cancelled(waitedNS: timer.elapsedTime().nanoseconds)
                }
            case .compileRunning:
                let elapsedNS = timer.elapsedTime().nanoseconds
                if elapsedNS >= timeoutNS {
                    let stoppedWaiting = observation.withLock { current in
                        guard current == .compileRunning else { return false }
                        current = .aborted("fingerprint_timeout")
                        return true
                    }
                    if stoppedWaiting {
                        return .appleFallback(reason: "fingerprint_timeout", waitedNS: elapsedNS)
                    }
                }
                do {
                    try await _Concurrency.Task<Never, Never>.sleep(nanoseconds: 1_000_000)
                } catch {
                    return .cancelled(waitedNS: timer.elapsedTime().nanoseconds)
                }
            case .aborted(let reason):
                return .appleFallback(reason: reason, waitedNS: timer.elapsedTime().nanoseconds)
            case .fingerprint(let fingerprint):
                guard fingerprint == configuration.expectedInterfaceFingerprint else {
                    return .appleFallback(
                        reason: "interface_fingerprint_mismatch",
                        waitedNS: timer.elapsedTime().nanoseconds
                    )
                }
                do {
                    try validateSourceAndArtifacts(isCancelled: isCancelled)
                } catch is CancellationError {
                    return .cancelled(waitedNS: timer.elapsedTime().nanoseconds)
                } catch {
                    return .appleFallback(
                        reason: "artifact_validation_failed",
                        waitedNS: timer.elapsedTime().nanoseconds
                    )
                }
                let outputBytes = configuration.emitModuleArtifacts.reduce(Int64(0)) {
                    $0 + $1.byteCount
                }
                return .reuse(
                    outputCount: configuredOutputs.count,
                    outputBytes: outputBytes,
                    waitedNS: timer.elapsedTime().nanoseconds
                )
            }
        }
    }

    private func validateSourceAndArtifacts(
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        try validate(
            path: Path(configuration.changedSourcePath),
            expectedByteCount: nil,
            expectedSHA256: configuration.candidateSourceSHA256,
            isCancelled: isCancelled
        )
        for artifact in configuration.emitModuleArtifacts {
            try validate(
                path: Path(artifact.path),
                expectedByteCount: artifact.byteCount,
                expectedSHA256: artifact.sha256,
                isCancelled: isCancelled
            )
        }
    }

    private func validate(
        path: Path,
        expectedByteCount: Int64?,
        expectedSHA256: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        if isCancelled() || _Concurrency.Task<Never, Never>.isCancelled {
            throw CancellationError()
        }
        var symlinkDestinationExists = false
        guard fs.exists(path),
              !fs.isSymlink(path, &symlinkDestinationExists),
              try fs.getFileInfo(path).isFile else {
            throw StubError.error("Swift module artifact reuse input is missing or unsupported.")
        }
        let bytes = try fs.read(path)
        if let expectedByteCount, Int64(bytes.count) != expectedByteCount {
            throw StubError.error("Swift module artifact reuse byte count changed.")
        }
        if isCancelled() || _Concurrency.Task<Never, Never>.isCancelled {
            throw CancellationError()
        }
        let hash = SHA256Context()
        hash.add(bytes: bytes)
        guard hash.signature.asString == expectedSHA256 else {
            throw StubError.error("Swift module artifact reuse digest changed.")
        }
    }
}

#endif
