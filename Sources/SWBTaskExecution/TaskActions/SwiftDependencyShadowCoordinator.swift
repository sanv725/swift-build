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

package import SWBCore
package import SWBUtil

package struct SwiftDependencyShadowConfiguration: Codable, Sendable, Equatable {
    package static let schema = "swift-build-dependency-shadow-configuration-v1"
    package static let pathVariable = "SWIFT_BUILD_DEPENDENCY_SHADOW_CONFIG"

    package enum Mode: String, Codable, Sendable {
        case record
        case observe
        case admit
    }

    package let schema: String
    package let mode: Mode
    package let previousManifestPath: String
    package let resultPath: String
    package let changedSourceIdentities: [String]
    package let pathMappings: [SwiftDependencyPathMapping]
    package let recordModuleName: String?
    package let recordToolchainIdentity: String?
    package let recordPathPolicyIdentity: String?
    package let recordSourceIdentities: [String]?
    package let preclassifiedBodyEdit: Bool?

    package init(
        previousManifestPath: String,
        resultPath: String,
        changedSourceIdentities: [String],
        pathMappings: [SwiftDependencyPathMapping]
    ) {
        self.schema = Self.schema
        self.mode = .observe
        self.previousManifestPath = previousManifestPath
        self.resultPath = resultPath
        self.changedSourceIdentities = changedSourceIdentities.sorted()
        self.pathMappings = pathMappings
        self.recordModuleName = nil
        self.recordToolchainIdentity = nil
        self.recordPathPolicyIdentity = nil
        self.recordSourceIdentities = nil
        self.preclassifiedBodyEdit = nil
    }

    package init(
        recordingManifestAt previousManifestPath: String,
        resultPath: String,
        moduleName: String,
        toolchainIdentity: String,
        pathPolicyIdentity: String,
        sourceIdentities: [String],
        pathMappings: [SwiftDependencyPathMapping]
    ) {
        self.schema = Self.schema
        self.mode = .record
        self.previousManifestPath = previousManifestPath
        self.resultPath = resultPath
        self.changedSourceIdentities = []
        self.pathMappings = pathMappings
        self.recordModuleName = moduleName
        self.recordToolchainIdentity = toolchainIdentity
        self.recordPathPolicyIdentity = pathPolicyIdentity
        self.recordSourceIdentities = sourceIdentities.sorted()
        self.preclassifiedBodyEdit = nil
    }

    package init(
        admittingManifestAt previousManifestPath: String,
        resultPath: String,
        changedSourceIdentity: String,
        pathMappings: [SwiftDependencyPathMapping],
        preclassifiedBodyEdit: Bool = false
    ) {
        self.schema = Self.schema
        self.mode = .admit
        self.previousManifestPath = previousManifestPath
        self.resultPath = resultPath
        self.changedSourceIdentities = [changedSourceIdentity]
        self.pathMappings = pathMappings
        self.recordModuleName = nil
        self.recordToolchainIdentity = nil
        self.recordPathPolicyIdentity = nil
        self.recordSourceIdentities = nil
        self.preclassifiedBodyEdit = preclassifiedBodyEdit ? true : nil
    }

    package static func path(environment: [String: String]) throws -> Path? {
        guard let rawPath = environment[Self.pathVariable], !rawPath.isEmpty else { return nil }
        let path = Path(rawPath)
        guard path.isAbsolute else {
            throw StubError.error("\(Self.pathVariable) must be an absolute path.")
        }
        return path
    }

    package static func removeControlVariable(from environment: inout [String: String]) {
        environment.removeValue(forKey: pathVariable)
    }
}

package struct SwiftDependencyShadowResult: Codable, Sendable, Equatable {
    package static let schema = "swift-build-dependency-shadow-result-v1"

    package let schema: String
    package let outcome: String
    package let moduleName: String
    package let moduleStructureIdentity: String?
    package let currentDependencyIdentity: String?
    package let predictedAffectedSources: [String]
    package let predictedReusableSources: [String]
    package let pendingSources: [String]
    package let actualExecutedSources: [String]
    package let missingActualExecutions: [String]
    package let extraActualExecutions: [String]
    package let predictedCompilationCounts: [String: Int]
    package let actualExecutionCounts: [String: Int]
}

package final class SwiftDependencyShadowCoordinator: @unchecked Sendable {
    package struct Summary: Sendable, Equatable {
        package let outcome: String
        package let sourceIdentity: String
        package let predictedCount: Int
        package let actualCount: Int
        package let pendingCount: Int
    }

    private struct State {
        var scheduler: SwiftDependencyInvalidationScheduler?
        var recordedProjections: [String: SwiftDependencyFingerprintProjection] = [:]
        var bufferedProjections: [String: SwiftDependencyFingerprintProjection] = [:]
        var actualExecutionCounts: [String: Int] = [:]
    }

    private let configuration: SwiftDependencyShadowConfiguration
    private let previousManifest: SwiftDependencyModuleManifest?
    private let moduleName: String
    private let expectedSourceIdentities: [String]
    private let resultPath: Path
    private let manifestPath: Path
    private let state: SWBMutex<State>

    package convenience init(configurationPath: Path, fs: any FSProxy) throws {
        let configurationBytes = try fs.read(configurationPath)
        let configuration = try JSONDecoder().decode(
            SwiftDependencyShadowConfiguration.self,
            from: Data(configurationBytes.bytes)
        )
        guard configuration.schema == SwiftDependencyShadowConfiguration.schema else {
            throw StubError.error("Unsupported Swift dependency shadow configuration schema.")
        }
        let manifestPath = Path(configuration.previousManifestPath)
        let resultPath = Path(configuration.resultPath)
        guard manifestPath.isAbsolute, resultPath.isAbsolute else {
            throw StubError.error("Swift dependency shadow manifest and result paths must be absolute.")
        }
        switch configuration.mode {
        case .record:
            try self.init(configuration: configuration, previousManifest: nil)
        case .observe:
            let manifestBytes = try fs.read(manifestPath)
            let manifest = try JSONDecoder().decode(
                SwiftDependencyModuleManifest.self,
                from: Data(manifestBytes.bytes)
            )
            try self.init(configuration: configuration, previousManifest: manifest)
        case .admit:
            throw StubError.error(
                "Swift dependency admission configuration requires the admission coordinator."
            )
        }
    }

    package init(
        configuration: SwiftDependencyShadowConfiguration,
        previousManifest: SwiftDependencyModuleManifest?
    ) throws {
        guard configuration.schema == SwiftDependencyShadowConfiguration.schema else {
            throw StubError.error("Swift dependency shadow state has an unsupported schema.")
        }
        let manifestPath = Path(configuration.previousManifestPath)
        let resultPath = Path(configuration.resultPath)
        guard manifestPath.isAbsolute, resultPath.isAbsolute else {
            throw StubError.error("Swift dependency shadow manifest and result paths must be absolute.")
        }
        let moduleName: String
        let sourceIdentities: [String]
        let scheduler: SwiftDependencyInvalidationScheduler?
        switch configuration.mode {
        case .record:
            guard previousManifest == nil,
                  let configuredModuleName = configuration.recordModuleName,
                  !configuredModuleName.isEmpty,
                  let toolchainIdentity = configuration.recordToolchainIdentity,
                  !toolchainIdentity.isEmpty,
                  let pathPolicyIdentity = configuration.recordPathPolicyIdentity,
                  !pathPolicyIdentity.isEmpty,
                  let configuredSources = configuration.recordSourceIdentities,
                  !configuredSources.isEmpty,
                  Set(configuredSources).count == configuredSources.count,
                  configuredSources.allSatisfy({ Path($0).isAbsolute }) else {
                throw StubError.error("Swift dependency shadow record configuration is incomplete.")
            }
            moduleName = configuredModuleName
            sourceIdentities = configuredSources.sorted()
            scheduler = nil
        case .observe:
            guard let previousManifest,
                  previousManifest.schema == SwiftDependencyModuleManifest.schema else {
                throw StubError.error("Swift dependency shadow observe mode requires a prior manifest.")
            }
            moduleName = previousManifest.moduleName
            sourceIdentities = previousManifest.sources.map(\.sourceIdentity)
            scheduler = try SwiftDependencyInvalidationScheduler(
                previousManifest: previousManifest,
                expectedSourceIdentities: sourceIdentities,
                changedSourceIdentities: Set(configuration.changedSourceIdentities)
            )
        case .admit:
            throw StubError.error(
                "Swift dependency admission configuration requires the admission coordinator."
            )
        }
        self.configuration = configuration
        self.previousManifest = previousManifest
        self.moduleName = moduleName
        self.expectedSourceIdentities = sourceIdentities
        self.resultPath = resultPath
        self.manifestPath = manifestPath
        self.state = SWBMutex(.init(scheduler: scheduler))
    }

    package func observeFrontend(
        moduleName: String,
        primaryPath: Path,
        dependencyPath: Path,
        fs: any FSProxy
    ) throws -> Summary {
        guard moduleName == self.moduleName else {
            throw StubError.error("Swift dependency shadow observation belongs to another module.")
        }
        let sourceIdentity = try normalizedSourceIdentity(primaryPath.str)
        let projection = try SwiftDependencyFingerprintProjection.read(
            from: dependencyPath,
            sourceIdentity: sourceIdentity,
            pathMappings: configuration.pathMappings
        )
        return try observeProjection(projection, sourceIdentity: sourceIdentity, fs: fs)
    }

    package func observeProjection(
        _ projection: SwiftDependencyFingerprintProjection,
        sourceIdentity: String,
        fs: any FSProxy
    ) throws -> Summary {
        try state.withLock { state in
            let expectedSources = Set(expectedSourceIdentities)
            guard expectedSources.contains(sourceIdentity) else {
                throw StubError.error("Swift dependency shadow observed an unknown primary source.")
            }
            state.actualExecutionCounts[sourceIdentity, default: 0] += 1
            switch configuration.mode {
            case .record:
                guard projection.schema == SwiftDependencyFingerprintProjection.schema,
                      projection.sourceFileInterfaceFingerprint != nil,
                      let toolchainIdentity = configuration.recordToolchainIdentity,
                      let pathPolicyIdentity = configuration.recordPathPolicyIdentity else {
                    throw StubError.error("Swift dependency shadow recorder received an invalid projection.")
                }
                state.recordedProjections[sourceIdentity] = projection
                let pending = expectedSources
                    .subtracting(Set(state.recordedProjections.keys))
                    .sorted()
                let actual = Set(state.actualExecutionCounts.keys)
                let completedManifest: SwiftDependencyModuleManifest?
                if pending.isEmpty {
                    let manifest = try SwiftDependencyModuleManifest(
                        moduleName: moduleName,
                        toolchainIdentity: toolchainIdentity,
                        pathPolicyIdentity: pathPolicyIdentity,
                        expectedSourceIdentities: expectedSourceIdentities,
                        projectionsBySource: state.recordedProjections
                    )
                    try persistManifest(manifest, fs: fs)
                    completedManifest = manifest
                } else {
                    completedManifest = nil
                }
                let outcome = completedManifest == nil ? "collecting" : "recorded"
                let result = SwiftDependencyShadowResult(
                    schema: SwiftDependencyShadowResult.schema,
                    outcome: outcome,
                    moduleName: moduleName,
                    moduleStructureIdentity: completedManifest?.structureIdentity,
                    currentDependencyIdentity: completedManifest?.dependencyIdentity,
                    predictedAffectedSources: [],
                    predictedReusableSources: [],
                    pendingSources: pending,
                    actualExecutedSources: actual.sorted(),
                    missingActualExecutions: [],
                    extraActualExecutions: [],
                    predictedCompilationCounts: [:],
                    actualExecutionCounts: state.actualExecutionCounts
                )
                try persistResult(result, fs: fs)
                return .init(
                    outcome: outcome,
                    sourceIdentity: sourceIdentity,
                    predictedCount: 0,
                    actualCount: actual.count,
                    pendingCount: pending.count
                )
            case .observe:
                guard let previousManifest, var scheduler = state.scheduler else {
                    throw StubError.error("Swift dependency shadow observe state is unavailable.")
                }
                state.bufferedProjections[sourceIdentity] = projection
                var madeProgress = true
                while madeProgress {
                    madeProgress = false
                    for pendingSource in scheduler.pendingSourceIdentities {
                        guard let pendingProjection = state.bufferedProjections.removeValue(
                            forKey: pendingSource
                        ) else { continue }
                        try scheduler.recordCompiledProjection(
                            pendingProjection,
                            for: pendingSource
                        )
                        madeProgress = true
                    }
                }
                state.scheduler = scheduler

                let predicted = Set(scheduler.affectedSourceIdentities)
                let actual = Set(state.actualExecutionCounts.keys)
                let pending = scheduler.pendingSourceIdentities
                let outcome: String
                let currentDependencyIdentity: String?
                if scheduler.isComplete {
                    outcome = predicted == actual ? "parity" : "mismatch"
                    currentDependencyIdentity = try scheduler.result().manifest.dependencyIdentity
                } else {
                    outcome = "pending"
                    currentDependencyIdentity = nil
                }
                let result = SwiftDependencyShadowResult(
                    schema: SwiftDependencyShadowResult.schema,
                    outcome: outcome,
                    moduleName: previousManifest.moduleName,
                    moduleStructureIdentity: previousManifest.structureIdentity,
                    currentDependencyIdentity: currentDependencyIdentity,
                    predictedAffectedSources: predicted.sorted(),
                    predictedReusableSources: expectedSources.subtracting(predicted).sorted(),
                    pendingSources: pending,
                    actualExecutedSources: actual.sorted(),
                    missingActualExecutions: predicted.subtracting(actual).sorted(),
                    extraActualExecutions: actual.subtracting(predicted).sorted(),
                    predictedCompilationCounts: scheduler.compilationCounts,
                    actualExecutionCounts: state.actualExecutionCounts
                )
                try persistResult(result, fs: fs)
                return .init(
                    outcome: outcome,
                    sourceIdentity: sourceIdentity,
                    predictedCount: predicted.count,
                    actualCount: actual.count,
                    pendingCount: pending.count
                )
            case .admit:
                throw StubError.error(
                    "Swift dependency admission configuration requires the admission coordinator."
                )
            }
        }
    }

    private func persistManifest(
        _ manifest: SwiftDependencyModuleManifest,
        fs: any FSProxy
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try fs.createDirectory(manifestPath.dirname, recursive: true)
        try fs.write(
            manifestPath,
            contents: ByteString(try encoder.encode(manifest)),
            atomically: true
        )
    }

    private func persistResult(
        _ result: SwiftDependencyShadowResult,
        fs: any FSProxy
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try fs.createDirectory(resultPath.dirname, recursive: true)
        try fs.write(
            resultPath,
            contents: ByteString(try encoder.encode(result)),
            atomically: true
        )
    }

    private func normalizedSourceIdentity(_ value: String) throws -> String {
        let expectedSources = Set(expectedSourceIdentities)
        if expectedSources.contains(value) { return value }
        for mapping in configuration.pathMappings.sorted(by: {
            $0.physicalPrefix.utf8.count > $1.physicalPrefix.utf8.count
        }) {
            if let mapped = mapping.map(value), expectedSources.contains(mapped) {
                return mapped
            }
        }
        throw StubError.error("Swift dependency shadow could not map the primary source identity.")
    }
}

#endif
