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

package enum SwiftDependencyAdmissionDecision: Sendable, Equatable {
    case executeChanged(sourceIdentity: String)
    case executeAffected(sourceIdentity: String)
    case replayReusable(
        sourceIdentity: String,
        dependencyFingerprintDigests: [String]
    )
    case appleFallback(sourceIdentity: String, reason: String)

    package var sourceIdentity: String {
        switch self {
        case .executeChanged(let sourceIdentity),
             .executeAffected(let sourceIdentity),
             .replayReusable(let sourceIdentity, _),
             .appleFallback(let sourceIdentity, _):
            sourceIdentity
        }
    }
}

package enum SwiftDependencyRuntimeCoordinator: Sendable {
    case shadow(SwiftDependencyShadowCoordinator)
    case admission(SwiftDependencyAdmissionCoordinator)
}

package final class SwiftDependencyAdmissionCoordinator: @unchecked Sendable {
    package struct Completion: Sendable, Equatable {
        package let outcome: String
        package let sourceIdentity: String
        package let dependencyFingerprintDigests: [String]
        package let predictedCount: Int
        package let actualCount: Int
        package let pendingCount: Int
    }

    package struct Snapshot: Sendable, Equatable {
        package let pendingSources: [String]
        package let dispatchedSources: [String]
        package let waitingSources: [String]
        package let actualExecutionCounts: [String: Int]
        package let abortedReason: String?
    }

    private typealias Waiter = CheckedContinuation<SwiftDependencyAdmissionDecision, Never>
    private typealias Resumption = (Waiter, SwiftDependencyAdmissionDecision)

    private struct State {
        var scheduler: SwiftDependencyInvalidationScheduler
        var preclassifiedChangedSource: String?
        var dispatchedSources: Set<String> = []
        var waiters: [String: [Waiter]] = [:]
        var actualExecutionCounts: [String: Int] = [:]
        var fixedPointResult: SwiftDependencyFixedPointResult?
        var replayCompletedSources: Set<String> = []
        var replayFallbackSources: Set<String> = []
        var abortedReason: String?
    }

    private struct CompletionTransition {
        let completion: Completion
        let resumptions: [Resumption]
        let result: SwiftDependencyShadowResult?
    }

    private let configuration: SwiftDependencyShadowConfiguration
    private let previousManifest: SwiftDependencyModuleManifest
    private let expectedSources: Set<String>
    private let resultPath: Path
    private let fs: any FSProxy
    private let state: SWBMutex<State>

    package convenience init(configurationPath: Path, fs: any FSProxy) throws {
        let configurationBytes = try fs.read(configurationPath)
        let configuration = try JSONDecoder().decode(
            SwiftDependencyShadowConfiguration.self,
            from: Data(configurationBytes.bytes)
        )
        let manifestPath = Path(configuration.previousManifestPath)
        guard manifestPath.isAbsolute else {
            throw StubError.error("Swift dependency admission manifest path must be absolute.")
        }
        let manifestBytes = try fs.read(manifestPath)
        let manifest = try JSONDecoder().decode(
            SwiftDependencyModuleManifest.self,
            from: Data(manifestBytes.bytes)
        )
        try self.init(
            configuration: configuration,
            previousManifest: manifest,
            fs: fs
        )
    }

    package init(
        configuration: SwiftDependencyShadowConfiguration,
        previousManifest: SwiftDependencyModuleManifest,
        fs: any FSProxy
    ) throws {
        guard configuration.schema == SwiftDependencyShadowConfiguration.schema,
              configuration.mode == .admit,
              previousManifest.schema == SwiftDependencyModuleManifest.schema,
              configuration.changedSourceIdentities.count == 1 else {
            throw StubError.error(
                "Swift dependency admission requires one changed source and a complete prior manifest."
            )
        }
        let resultPath = Path(configuration.resultPath)
        guard resultPath.isAbsolute else {
            throw StubError.error("Swift dependency admission result path must be absolute.")
        }
        let sourceIdentities = previousManifest.sources.map(\.sourceIdentity)
        var scheduler = try SwiftDependencyInvalidationScheduler(
            previousManifest: previousManifest,
            expectedSourceIdentities: sourceIdentities,
            changedSourceIdentities: Set(configuration.changedSourceIdentities)
        )
        let preclassifiedChangedSource: String?
        let fixedPointResult: SwiftDependencyFixedPointResult?
        if let proof = configuration.preclassifiedBodyEditProof {
            let changedSource = configuration.changedSourceIdentities[0]
            try Self.validate(
                proof: proof,
                changedSource: changedSource,
                pathMappings: configuration.pathMappings,
                fs: fs
            )
            try scheduler.preclassifyChangedSourceAsInterfaceStable(changedSource)
            preclassifiedChangedSource = changedSource
            fixedPointResult = try scheduler.result()
        } else if configuration.preclassifiedBodyEdit == true {
            let changedSource = configuration.changedSourceIdentities[0]
            try scheduler.preclassifyChangedSourceAsInterfaceStable(changedSource)
            preclassifiedChangedSource = changedSource
            fixedPointResult = try scheduler.result()
        } else {
            preclassifiedChangedSource = nil
            fixedPointResult = nil
        }
        self.configuration = configuration
        self.previousManifest = previousManifest
        self.expectedSources = Set(sourceIdentities)
        self.resultPath = resultPath
        self.fs = fs
        self.state = SWBMutex(.init(
            scheduler: scheduler,
            preclassifiedChangedSource: preclassifiedChangedSource,
            fixedPointResult: fixedPointResult
        ))
    }

    private static func validate(
        proof: SwiftDependencyBodyEditProof,
        changedSource: String,
        pathMappings: [SwiftDependencyPathMapping],
        fs: any FSProxy
    ) throws {
        func isSHA256(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                    || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
            }
        }

        guard proof.schema == SwiftDependencyBodyEditProof.schema,
              proof.classifierVersion == SwiftDependencyBodyEditProof.classifierVersion,
              proof.sourceIdentity == changedSource,
              isSHA256(proof.baselineSHA256),
              isSHA256(proof.candidateSHA256),
              proof.baselineSHA256 != proof.candidateSHA256,
              isSHA256(proof.surfaceSHA256),
              !proof.changedBodyOrdinals.isEmpty,
              proof.changedBodyOrdinals == Array(Set(proof.changedBodyOrdinals)).sorted(),
              proof.changedBodyOrdinals.allSatisfy({ $0 >= 0 }) else {
            throw StubError.error("Swift dependency body-edit proof is invalid.")
        }
        let sourcePath = pathMappings.lazy.compactMap { mapping -> Path? in
            guard changedSource == mapping.virtualPrefix
                    || changedSource.hasPrefix(mapping.virtualPrefix + "/") else {
                return nil
            }
            return Path(mapping.physicalPrefix + changedSource.dropFirst(mapping.virtualPrefix.count))
        }.first
        guard let sourcePath, sourcePath.isAbsolute, fs.exists(sourcePath) else {
            throw StubError.error("Swift dependency body-edit proof source cannot be resolved.")
        }
        let bytes = try fs.read(sourcePath)
        let hash = SHA256Context()
        hash.add(bytes: bytes)
        guard hash.signature.asString == proof.candidateSHA256 else {
            throw StubError.error("Swift dependency body-edit proof does not match the active source.")
        }
    }

    package func admissionDecision(
        moduleName: String,
        primaryPath: Path
    ) async -> SwiftDependencyAdmissionDecision {
        let sourceIdentity: String
        do {
            guard moduleName == previousManifest.moduleName else {
                throw StubError.error("Swift dependency admission observed another module.")
            }
            sourceIdentity = try normalizedSourceIdentity(primaryPath.str)
        } catch {
            let fallbackIdentity = primaryPath.str
            abort(reason: "invalid_primary")
            return .appleFallback(
                sourceIdentity: fallbackIdentity,
                reason: "invalid_primary"
            )
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(continuation: continuation, sourceIdentity: sourceIdentity)
            }
        } onCancel: {
            self.abort(reason: "cancelled")
        }
    }

    package func completeFrontend(
        sourceIdentity: String,
        dependencyPath: Path
    ) throws -> Completion {
        let projection = try SwiftDependencyFingerprintProjection.read(
            from: dependencyPath,
            sourceIdentity: sourceIdentity,
            pathMappings: configuration.pathMappings
        )
        return try completeProjection(projection, sourceIdentity: sourceIdentity)
    }

    package func completeProjection(
        _ projection: SwiftDependencyFingerprintProjection,
        sourceIdentity: String
    ) throws -> Completion {
        let transition: CompletionTransition
        do {
            transition = try state.withLock { state in
                if state.preclassifiedChangedSource == sourceIdentity {
                    guard state.dispatchedSources.remove(sourceIdentity) != nil else {
                        throw StubError.error(
                            "Swift dependency admission completed an undispatched preclassified source."
                        )
                    }
                    try state.scheduler.recordPreclassifiedProjection(
                        projection,
                        for: sourceIdentity
                    )
                    state.actualExecutionCounts[sourceIdentity, default: 0] += 1
                    let fixedPoint = try state.scheduler.result()
                    state.fixedPointResult = fixedPoint
                    guard let dependencyFingerprintDigests = state.scheduler
                        .dependencyFingerprintDigests(for: sourceIdentity) else {
                        throw StubError.error(
                            "Swift dependency admission could not resolve preclassified dependencies."
                        )
                    }
                    let reusableCount = fixedPoint.invalidationCone.reusableSources.count
                    let replaysComplete = state.replayCompletedSources.count == reusableCount
                    let outcome = replaysComplete && !state.replayFallbackSources.isEmpty
                        ? "replay_fallback"
                        : "admitted"
                    let persistedOutcome = replaysComplete
                        ? outcome
                        : "admitted_pending_replays"
                    return .init(
                        completion: .init(
                            outcome: outcome,
                            sourceIdentity: sourceIdentity,
                            dependencyFingerprintDigests: dependencyFingerprintDigests,
                            predictedCount: fixedPoint.invalidationCone.affectedSources.count,
                            actualCount: state.actualExecutionCounts.count,
                            pendingCount: 0
                        ),
                        resumptions: [],
                        result: makeResult(
                            outcome: persistedOutcome,
                            fixedPoint: fixedPoint,
                            actualExecutionCounts: state.actualExecutionCounts
                        )
                    )
                }
                guard state.abortedReason == nil,
                      state.dispatchedSources.remove(sourceIdentity) != nil,
                      state.scheduler.pendingSourceIdentities.contains(sourceIdentity) else {
                    throw StubError.error(
                        "Swift dependency admission completed an undispatched source."
                    )
                }
                try state.scheduler.recordCompiledProjection(
                    projection,
                    for: sourceIdentity
                )
                state.actualExecutionCounts[sourceIdentity, default: 0] += 1
                guard let dependencyFingerprintDigests = state.scheduler
                    .dependencyFingerprintDigests(for: sourceIdentity) else {
                    throw StubError.error(
                        "Swift dependency admission could not resolve compiled dependencies."
                    )
                }

                var resumptions: [Resumption] = []
                for pendingSource in state.scheduler.pendingSourceIdentities {
                    guard !state.dispatchedSources.contains(pendingSource),
                          let waiters = state.waiters.removeValue(forKey: pendingSource) else {
                        continue
                    }
                    guard waiters.count == 1 else {
                        throw StubError.error(
                            "Swift dependency admission observed duplicate source jobs."
                        )
                    }
                    state.dispatchedSources.insert(pendingSource)
                    resumptions.append((
                        waiters[0],
                        .executeAffected(sourceIdentity: pendingSource)
                    ))
                }

                var persistedResult: SwiftDependencyShadowResult?
                let outcome: String
                if state.scheduler.isComplete {
                    let fixedPoint = try state.scheduler.result()
                    state.fixedPointResult = fixedPoint
                    let currentEntries = Dictionary(
                        uniqueKeysWithValues: fixedPoint.manifest.sources.map {
                            ($0.sourceIdentity, $0)
                        }
                    )
                    let affected = Set(fixedPoint.invalidationCone.affectedSources)
                    for waitingSource in state.waiters.keys.sorted() {
                        guard !affected.contains(waitingSource),
                              let entry = currentEntries[waitingSource],
                              let waiters = state.waiters.removeValue(forKey: waitingSource),
                              waiters.count == 1 else {
                            throw StubError.error(
                                "Swift dependency admission could not classify a waiting source."
                            )
                        }
                        resumptions.append((
                            waiters[0],
                            .replayReusable(
                                sourceIdentity: waitingSource,
                                dependencyFingerprintDigests: entry.dependencyFingerprintDigests
                            )
                        ))
                    }
                    outcome = "admitted"
                    persistedResult = makeResult(
                        outcome: outcome,
                        fixedPoint: fixedPoint,
                        actualExecutionCounts: state.actualExecutionCounts
                    )
                } else {
                    outcome = "progress"
                }
                return .init(
                    completion: .init(
                        outcome: outcome,
                        sourceIdentity: sourceIdentity,
                        dependencyFingerprintDigests: dependencyFingerprintDigests,
                        predictedCount: state.scheduler.affectedSourceIdentities.count,
                        actualCount: state.actualExecutionCounts.count,
                        pendingCount: state.scheduler.pendingSourceIdentities.count
                    ),
                    resumptions: resumptions,
                    result: persistedResult
                )
            }
        } catch {
            abort(reason: "invalid_projection")
            throw error
        }

        resume(transition.resumptions)
        if let result = transition.result {
            try? persistResult(result)
        }
        return transition.completion
    }

    package func recordReplayFallbackExecution(sourceIdentity: String) {
        recordReplayCompletion(sourceIdentity: sourceIdentity, executedApple: true)
    }

    package func recordReplayHit(sourceIdentity: String) {
        recordReplayCompletion(sourceIdentity: sourceIdentity, executedApple: false)
    }

    private func recordReplayCompletion(
        sourceIdentity: String,
        executedApple: Bool
    ) {
        let result = state.withLock { state -> SwiftDependencyShadowResult? in
            guard let fixedPoint = state.fixedPointResult,
                  fixedPoint.invalidationCone.reusableSources.contains(sourceIdentity),
                  state.replayCompletedSources.insert(sourceIdentity).inserted else {
                return nil
            }
            if executedApple {
                state.actualExecutionCounts[sourceIdentity, default: 0] += 1
                state.replayFallbackSources.insert(sourceIdentity)
            }
            guard state.replayCompletedSources.count
                    == fixedPoint.invalidationCone.reusableSources.count else {
                return nil
            }
            return makeResult(
                outcome: state.replayFallbackSources.isEmpty
                    ? "admitted"
                    : "replay_fallback",
                fixedPoint: fixedPoint,
                actualExecutionCounts: state.actualExecutionCounts
            )
        }
        if let result {
            try? persistResult(result)
        }
    }

    package func abort(reason: String) {
        let resumptions = state.withLock { state -> [Resumption] in
            guard state.abortedReason == nil else { return [] }
            state.abortedReason = reason
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters.keys.sorted().flatMap { sourceIdentity in
                waiters[sourceIdentity, default: []].map {
                    ($0, .appleFallback(sourceIdentity: sourceIdentity, reason: reason))
                }
            }
        }
        resume(resumptions)
    }

    package func snapshot() -> Snapshot {
        state.withLock { state in
            .init(
                pendingSources: state.scheduler.pendingSourceIdentities,
                dispatchedSources: state.dispatchedSources.sorted(),
                waitingSources: state.waiters.keys.sorted(),
                actualExecutionCounts: state.actualExecutionCounts,
                abortedReason: state.abortedReason
            )
        }
    }

    private func register(
        continuation: Waiter,
        sourceIdentity: String
    ) {
        var resumptions: [Resumption] = []
        state.withLock { state in
            if let reason = state.abortedReason {
                resumptions.append((
                    continuation,
                    .appleFallback(sourceIdentity: sourceIdentity, reason: reason)
                ))
                return
            }
            if state.preclassifiedChangedSource == sourceIdentity {
                guard !state.dispatchedSources.contains(sourceIdentity) else {
                    state.abortedReason = "duplicate_source"
                    resumptions.append((
                        continuation,
                        .appleFallback(sourceIdentity: sourceIdentity, reason: "duplicate_source")
                    ))
                    return
                }
                state.dispatchedSources.insert(sourceIdentity)
                resumptions.append((
                    continuation,
                    .executeChanged(sourceIdentity: sourceIdentity)
                ))
                return
            }
            guard expectedSources.contains(sourceIdentity) else {
                state.abortedReason = "unknown_source"
                resumptions.append((
                    continuation,
                    .appleFallback(sourceIdentity: sourceIdentity, reason: "unknown_source")
                ))
                for waitingSource in state.waiters.keys.sorted() {
                    for waiter in state.waiters[waitingSource, default: []] {
                        resumptions.append((
                            waiter,
                            .appleFallback(
                                sourceIdentity: waitingSource,
                                reason: "unknown_source"
                            )
                        ))
                    }
                }
                state.waiters.removeAll()
                return
            }
            if state.scheduler.pendingSourceIdentities.contains(sourceIdentity),
               !state.dispatchedSources.contains(sourceIdentity) {
                state.dispatchedSources.insert(sourceIdentity)
                let isChanged = configuration.changedSourceIdentities.contains(sourceIdentity)
                resumptions.append((
                    continuation,
                    isChanged
                        ? .executeChanged(sourceIdentity: sourceIdentity)
                        : .executeAffected(sourceIdentity: sourceIdentity)
                ))
                return
            }
            if state.scheduler.isComplete,
               let entry = state.fixedPointResult?.manifest.sources.first(
                   where: { $0.sourceIdentity == sourceIdentity }
               ),
               !state.scheduler.affectedSourceIdentities.contains(sourceIdentity) {
                resumptions.append((
                    continuation,
                    .replayReusable(
                        sourceIdentity: sourceIdentity,
                        dependencyFingerprintDigests: entry.dependencyFingerprintDigests
                    )
                ))
                return
            }
            state.waiters[sourceIdentity, default: []].append(continuation)
        }
        resume(resumptions)
    }

    private func resume(_ resumptions: [Resumption]) {
        for (continuation, decision) in resumptions {
            continuation.resume(returning: decision)
        }
    }

    private func makeResult(
        outcome: String,
        fixedPoint: SwiftDependencyFixedPointResult,
        actualExecutionCounts: [String: Int]
    ) -> SwiftDependencyShadowResult {
        let predicted = Set(fixedPoint.invalidationCone.affectedSources)
        let actual = Set(actualExecutionCounts.keys)
        return .init(
            schema: SwiftDependencyShadowResult.schema,
            outcome: outcome,
            moduleName: previousManifest.moduleName,
            moduleStructureIdentity: previousManifest.structureIdentity,
            currentDependencyIdentity: fixedPoint.manifest.dependencyIdentity,
            predictedAffectedSources: predicted.sorted(),
            predictedReusableSources: expectedSources.subtracting(predicted).sorted(),
            pendingSources: [],
            actualExecutedSources: actual.sorted(),
            missingActualExecutions: predicted.subtracting(actual).sorted(),
            extraActualExecutions: actual.subtracting(predicted).sorted(),
            predictedCompilationCounts: fixedPoint.compilationCounts,
            actualExecutionCounts: actualExecutionCounts
        )
    }

    private func persistResult(_ result: SwiftDependencyShadowResult) throws {
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
        if expectedSources.contains(value) { return value }
        for mapping in configuration.pathMappings.sorted(by: {
            $0.physicalPrefix.utf8.count > $1.physicalPrefix.utf8.count
        }) {
            if let mapped = mapping.map(value), expectedSources.contains(mapped) {
                return mapped
            }
        }
        throw StubError.error("Swift dependency admission could not map a primary source.")
    }
}

#endif
