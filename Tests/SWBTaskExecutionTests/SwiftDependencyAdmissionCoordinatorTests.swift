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

import SWBCore
import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SwiftDependencyAdmissionCoordinatorTests {
    private let provider = "/^src/Provider.swift"
    private let caller = "/^src/Caller.swift"
    private let unrelated = "/^src/Unrelated.swift"

    @Test
    func bodyEditSuspendsThenReplaysEveryReusablePrimary() async throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let coordinator = try makeCoordinator(temporaryDirectory: temporaryDirectory)

        let providerDecision = await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(provider)
        )
        #expect(providerDecision == .executeChanged(sourceIdentity: provider))

        async let callerDecision = coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(caller)
        )
        async let unrelatedDecision = coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(unrelated)
        )
        #expect(await waitForWaiters(coordinator, expected: [caller, unrelated]))

        let completion = try coordinator.completeProjection(
            providerProjection(fingerprint: "provider-v1"),
            sourceIdentity: provider
        )
        #expect(completion.outcome == "admitted")
        #expect(completion.predictedCount == 1)
        #expect(completion.actualCount == 1)
        #expect(completion.pendingCount == 0)
        let expectedCallerDependencyDigests = try baselineCallerDependencyDigests()
        #expect(await callerDecision == .replayReusable(
            sourceIdentity: caller,
            dependencyFingerprintDigests: expectedCallerDependencyDigests
        ))
        #expect(await unrelatedDecision == .replayReusable(
            sourceIdentity: unrelated,
            dependencyFingerprintDigests: []
        ))

        coordinator.recordReplayHit(sourceIdentity: caller)
        let partialResult = try readResult(temporaryDirectory: temporaryDirectory)
        #expect(partialResult.outcome == "admitted")
        #expect(partialResult.actualExecutedSources == [provider])

        coordinator.recordReplayFallbackExecution(sourceIdentity: unrelated)
        let finalResult = try readResult(temporaryDirectory: temporaryDirectory)
        #expect(finalResult.outcome == "replay_fallback")
        #expect(finalResult.predictedAffectedSources == [provider])
        #expect(finalResult.predictedReusableSources == [caller, unrelated])
        #expect(finalResult.actualExecutedSources == [provider, unrelated])
        #expect(finalResult.extraActualExecutions == [unrelated])
    }

    @Test
    func preclassifiedBodyEditNeverSuspendsReusablePrimaries() async throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let candidatePath = temporaryDirectory.path.join("Provider.swift")
        let candidate = ByteString(encodingAsUTF8: "func provider() -> Int { 727 }\n")
        try localFS.write(candidatePath, contents: candidate)
        let candidateHash = SHA256Context()
        candidateHash.add(bytes: candidate)
        let coordinator = try makeCoordinator(
            temporaryDirectory: temporaryDirectory,
            preclassifiedBodyEditProof: .init(
                sourceIdentity: provider,
                baselineSHA256: String(repeating: "a", count: 64),
                candidateSHA256: candidateHash.signature.asString,
                surfaceSHA256: String(repeating: "b", count: 64),
                changedBodyOrdinals: [0]
            ),
            pathMappings: [.init(
                physicalPrefix: temporaryDirectory.path.str,
                virtualPrefix: "/^src"
            )]
        )

        let callerDecision = await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(caller)
        )
        #expect(callerDecision == .replayReusable(
            sourceIdentity: caller,
            dependencyFingerprintDigests: try baselineCallerDependencyDigests()
        ))
        let unrelatedDecision = await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(unrelated)
        )
        #expect(unrelatedDecision == .replayReusable(
            sourceIdentity: unrelated,
            dependencyFingerprintDigests: []
        ))
        #expect(coordinator.snapshot().waitingSources.isEmpty)

        let providerDecision = await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(provider)
        )
        #expect(providerDecision == .executeChanged(sourceIdentity: provider))
        coordinator.recordReplayHit(sourceIdentity: caller)
        coordinator.recordReplayHit(sourceIdentity: unrelated)

        let completion = try coordinator.completeProjection(
            providerProjection(fingerprint: "provider-v1"),
            sourceIdentity: provider
        )
        #expect(completion.outcome == "admitted")
        #expect(completion.predictedCount == 1)
        #expect(completion.actualCount == 1)
        #expect(completion.pendingCount == 0)
        let result = try readResult(temporaryDirectory: temporaryDirectory)
        #expect(result.outcome == "admitted")
        #expect(result.predictedAffectedSources == [provider])
        #expect(result.predictedReusableSources == [caller, unrelated])
        #expect(result.actualExecutedSources == [provider])
    }

    @Test
    func rejectsAStalePreclassifiedBodyEditProof() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        try localFS.write(
            temporaryDirectory.path.join("Provider.swift"),
            contents: ByteString(encodingAsUTF8: "func provider() -> Int { 728 }\n")
        )
        #expect(throws: (any Error).self) {
            try makeCoordinator(
                temporaryDirectory: temporaryDirectory,
                preclassifiedBodyEditProof: .init(
                    sourceIdentity: provider,
                    baselineSHA256: String(repeating: "a", count: 64),
                    candidateSHA256: String(repeating: "c", count: 64),
                    surfaceSHA256: String(repeating: "b", count: 64),
                    changedBodyOrdinals: [0]
                ),
                pathMappings: [.init(
                    physicalPrefix: temporaryDirectory.path.str,
                    virtualPrefix: "/^src"
                )]
            )
        }
    }

    @Test
    func persistsAdmissionWhenIncrementalPlanningOmitsReusablePrimaries() async throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let coordinator = try makeCoordinator(
            temporaryDirectory: temporaryDirectory,
            preclassifiedBodyEdit: true
        )
        #expect(await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(provider)
        ) == .executeChanged(sourceIdentity: provider))
        let completion = try coordinator.completeProjection(
            providerProjection(fingerprint: "provider-v1"),
            sourceIdentity: provider
        )
        #expect(completion.outcome == "admitted")
        let result = try readResult(temporaryDirectory: temporaryDirectory)
        #expect(result.outcome == "admitted_pending_replays")
        #expect(result.predictedReusableSources == [caller, unrelated])
        #expect(result.actualExecutedSources == [provider])
    }

    @Test
    func APIEditReleasesAffectedCallerBeforeReusablePrimary() async throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let coordinator = try makeCoordinator(temporaryDirectory: temporaryDirectory)
        let providerDecision = await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(provider)
        )
        #expect(providerDecision == .executeChanged(sourceIdentity: provider))

        async let callerDecision = coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(caller)
        )
        async let unrelatedDecision = coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(unrelated)
        )
        #expect(await waitForWaiters(coordinator, expected: [caller, unrelated]))

        let providerCompletion = try coordinator.completeProjection(
            providerProjection(fingerprint: "provider-v2"),
            sourceIdentity: provider
        )
        #expect(providerCompletion.outcome == "progress")
        #expect(providerCompletion.pendingCount == 1)
        #expect(await callerDecision == .executeAffected(sourceIdentity: caller))
        #expect(coordinator.snapshot().waitingSources == [unrelated])

        let callerCompletion = try coordinator.completeProjection(
            callerProjection(),
            sourceIdentity: caller
        )
        #expect(callerCompletion.outcome == "admitted")
        #expect(callerCompletion.predictedCount == 2)
        #expect(callerCompletion.actualCount == 2)
        #expect(await unrelatedDecision == .replayReusable(
            sourceIdentity: unrelated,
            dependencyFingerprintDigests: []
        ))

        let result = try readResult(temporaryDirectory: temporaryDirectory)
        #expect(result.predictedAffectedSources == [caller, provider])
        #expect(result.predictedReusableSources == [unrelated])
        #expect(result.actualExecutedSources == [caller, provider])
        #expect(result.missingActualExecutions.isEmpty)
        #expect(result.extraActualExecutions.isEmpty)
    }

    @Test
    func precomputedAPIEditClassifiesTheTransitiveConeBeforeAnyTaskWaits() async throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let configuration = SwiftDependencyShadowConfiguration(
            admittingManifestAt: temporaryDirectory.path.join("baseline.json").str,
            resultPath: temporaryDirectory.path.join("result.json").str,
            changedSourceIdentity: provider,
            pathMappings: [],
            preflightManifestPath: temporaryDirectory.path.join("preflight.json").str,
            compatiblePlanCandidateKey: String(repeating: "a", count: 64),
            compatiblePlanInputIdentity: String(repeating: "b", count: 64)
        )
        let currentManifest = try SwiftDependencyModuleManifest(
            moduleName: "AdmissionFixture",
            toolchainIdentity: "toolchain-v1",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: [provider, caller, unrelated],
            projectionsBySource: [
                provider: providerProjection(fingerprint: "provider-v2"),
                caller: callerProjection(),
                unrelated: unrelatedProjection(),
            ]
        )
        let coordinator = try SwiftDependencyAdmissionCoordinator(
            configuration: configuration,
            previousManifest: baselineManifest(),
            preflightManifest: currentManifest,
            fs: localFS
        )

        #expect(coordinator.usesPrecomputedInvalidation)
        let unrelatedDecision = await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(unrelated)
        )
        #expect(unrelatedDecision == .replayReusable(
            sourceIdentity: unrelated,
            dependencyFingerprintDigests: []
        ))
        let callerDecision = await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(caller)
        )
        #expect(callerDecision == .executeAffected(sourceIdentity: caller))
        let providerDecision = await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(provider)
        )
        #expect(providerDecision == .executeChanged(sourceIdentity: provider))
        #expect(coordinator.snapshot().waitingSources.isEmpty)

        let callerCompletion = try coordinator.completeProjection(
            callerProjection(),
            sourceIdentity: caller
        )
        #expect(callerCompletion.outcome == "progress")
        #expect(callerCompletion.pendingCount == 1)
        let providerCompletion = try coordinator.completeProjection(
            providerProjection(fingerprint: "provider-v2"),
            sourceIdentity: provider
        )
        #expect(providerCompletion.outcome == "admitted")
        #expect(providerCompletion.predictedCount == 2)
        #expect(providerCompletion.actualCount == 2)
        coordinator.recordReplayHit(sourceIdentity: unrelated)

        let result = try readResult(temporaryDirectory: temporaryDirectory)
        #expect(result.outcome == "admitted")
        #expect(result.predictedAffectedSources == [caller, provider])
        #expect(result.predictedReusableSources == [unrelated])
        #expect(result.actualExecutedSources == [caller, provider])
        #expect(result.missingActualExecutions.isEmpty)
        #expect(result.extraActualExecutions.isEmpty)
    }

    @Test
    func graphAdmissionRunsAffectedFrontendsTogetherAndPublishesOneFinalManifest() async throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let preflightPath = temporaryDirectory.path.join("preflight.json")
        let configuration = SwiftDependencyShadowConfiguration(
            admittingManifestAt: temporaryDirectory.path.join("baseline.json").str,
            resultPath: temporaryDirectory.path.join("result.json").str,
            changedSourceIdentity: provider,
            pathMappings: [],
            preflightManifestPath: preflightPath.str,
            compatiblePlanCandidateKey: String(repeating: "a", count: 64),
            compatiblePlanInputIdentity: String(repeating: "b", count: 64),
            compatiblePlanPreflightMode: .dependencyGraph
        )
        let baseline = try baselineManifest()
        let changed = providerProjection(fingerprint: "provider-v2")
        let closure = try SwiftDependencyPriorGraphClosure.calculate(
            previousManifest: baseline,
            changedProjections: [provider: changed]
        )
        let graphManifest = try SwiftDependencyGraphAdmissionManifest(
            previousManifest: baseline,
            closure: closure,
            changedProjections: [provider: changed]
        )
        let coordinator = try SwiftDependencyAdmissionCoordinator(
            configuration: configuration,
            previousManifest: baseline,
            graphAdmissionManifest: graphManifest,
            fs: localFS
        )

        #expect(coordinator.usesGraphAdmission)
        #expect(!coordinator.usesPreflightCompilerOutputs)
        #expect(await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(provider)
        ) == .executeChanged(sourceIdentity: provider))
        #expect(await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(caller)
        ) == .executeAffected(sourceIdentity: caller))
        #expect(await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(unrelated)
        ) == .replayReusable(sourceIdentity: unrelated, dependencyFingerprintDigests: []))
        coordinator.recordReplayHit(sourceIdentity: unrelated)

        async let providerCompletion = coordinator.completeGraphProjection(
            changed,
            sourceIdentity: provider
        )
        async let callerCompletion = coordinator.completeGraphProjection(
            callerProjection(),
            sourceIdentity: caller
        )
        let completions = try await [providerCompletion, callerCompletion]
        #expect(completions.allSatisfy { $0.outcome == "admitted" })
        #expect(completions.allSatisfy { $0.predictedCount == 2 })
        #expect(completions.allSatisfy { $0.actualCount == 2 })

        let bytes = try localFS.read(preflightPath)
        let finalManifest = try JSONDecoder().decode(
            SwiftDependencyModuleManifest.self,
            from: Data(bytes.bytes)
        )
        #expect(finalManifest.sources.first {
            $0.sourceIdentity == provider
        }?.projection == changed)
        let result = try readResult(temporaryDirectory: temporaryDirectory)
        #expect(result.outcome == "admitted")
        #expect(result.predictedAffectedSources == [caller, provider])
        #expect(result.actualExecutedSources == [caller, provider])
    }

    @Test
    func abortReleasesEverySuspendedJobToAppleFallback() async throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let coordinator = try makeCoordinator(temporaryDirectory: temporaryDirectory)
        _ = await coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(provider)
        )
        async let callerDecision = coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(caller)
        )
        async let unrelatedDecision = coordinator.admissionDecision(
            moduleName: "AdmissionFixture",
            primaryPath: Path(unrelated)
        )
        #expect(await waitForWaiters(coordinator, expected: [caller, unrelated]))

        coordinator.abort(reason: "frontend_failed")

        #expect(await callerDecision == .appleFallback(
            sourceIdentity: caller,
            reason: "frontend_failed"
        ))
        #expect(await unrelatedDecision == .appleFallback(
            sourceIdentity: unrelated,
            reason: "frontend_failed"
        ))
        #expect(coordinator.snapshot().waitingSources.isEmpty)
        #expect(coordinator.snapshot().abortedReason == "frontend_failed")
    }

    @Test
    func rejectsMultipleChangedRoots() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let configuration = SwiftDependencyShadowConfiguration(
            previousManifestPath: temporaryDirectory.path.join("manifest.json").str,
            resultPath: temporaryDirectory.path.join("result.json").str,
            changedSourceIdentities: [provider, caller],
            pathMappings: []
        )
        let admissionConfiguration = try JSONDecoder().decode(
            SwiftDependencyShadowConfiguration.self,
            from: replacingMode(in: configuration, with: "admit")
        )
        let manifest = try baselineManifest()
        #expect(throws: (any Error).self) {
            try SwiftDependencyAdmissionCoordinator(
                configuration: admissionConfiguration,
                previousManifest: manifest,
                fs: localFS
            )
        }
    }

    private func makeCoordinator(
        temporaryDirectory: NamedTemporaryDirectory,
        preclassifiedBodyEdit: Bool = false,
        preclassifiedBodyEditProof: SwiftDependencyBodyEditProof? = nil,
        pathMappings: [SwiftDependencyPathMapping] = []
    ) throws -> SwiftDependencyAdmissionCoordinator {
        let configuration = SwiftDependencyShadowConfiguration(
            admittingManifestAt: temporaryDirectory.path.join("manifest.json").str,
            resultPath: temporaryDirectory.path.join("result.json").str,
            changedSourceIdentity: provider,
            pathMappings: pathMappings,
            preclassifiedBodyEdit: preclassifiedBodyEdit,
            preclassifiedBodyEditProof: preclassifiedBodyEditProof
        )
        return try .init(
            configuration: configuration,
            previousManifest: baselineManifest(),
            fs: localFS
        )
    }

    private func waitForWaiters(
        _ coordinator: SwiftDependencyAdmissionCoordinator,
        expected: [String]
    ) async -> Bool {
        for _ in 0..<10_000 {
            if coordinator.snapshot().waitingSources == expected.sorted() {
                return true
            }
            await _Concurrency.Task<Never, Never>.yield()
        }
        return false
    }

    private func replacingMode(
        in configuration: SwiftDependencyShadowConfiguration,
        with mode: String
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(configuration)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["mode"] = mode
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func readResult(
        temporaryDirectory: NamedTemporaryDirectory
    ) throws -> SwiftDependencyShadowResult {
        let bytes = try localFS.read(temporaryDirectory.path.join("result.json"))
        return try JSONDecoder().decode(
            SwiftDependencyShadowResult.self,
            from: Data(bytes.bytes)
        )
    }

    private func baselineManifest() throws -> SwiftDependencyModuleManifest {
        try .init(
            moduleName: "AdmissionFixture",
            toolchainIdentity: "toolchain-v1",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: [provider, caller, unrelated],
            projectionsBySource: [
                provider: providerProjection(fingerprint: "provider-v1"),
                caller: callerProjection(),
                unrelated: unrelatedProjection(),
            ]
        )
    }

    private func baselineCallerDependencyDigests() throws -> [String] {
        let manifest = try baselineManifest()
        return try #require(
            manifest.sources.first(where: { $0.sourceIdentity == caller })
        ).dependencyFingerprintDigests
    }

    private func providerProjection(
        fingerprint: String
    ) -> SwiftDependencyFingerprintProjection {
        .init(
            compilerVersion: "Swift version 6.2.4",
            sourceFileInterfaceFingerprint: fingerprint,
            providedInterfaces: [.init(key: providerKey, fingerprint: nil)],
            dependedInterfaces: []
        )
    }

    private func callerProjection() -> SwiftDependencyFingerprintProjection {
        .init(
            compilerVersion: "Swift version 6.2.4",
            sourceFileInterfaceFingerprint: "caller-v1",
            providedInterfaces: [],
            dependedInterfaces: [providerKey]
        )
    }

    private func unrelatedProjection() -> SwiftDependencyFingerprintProjection {
        .init(
            compilerVersion: "Swift version 6.2.4",
            sourceFileInterfaceFingerprint: "unrelated-v1",
            providedInterfaces: [],
            dependedInterfaces: []
        )
    }

    private var providerKey: SwiftDependencyFingerprintProjection.Key {
        .init(kind: "top-level", aspect: "interface", context: nil, name: "provider")
    }
}

#endif
