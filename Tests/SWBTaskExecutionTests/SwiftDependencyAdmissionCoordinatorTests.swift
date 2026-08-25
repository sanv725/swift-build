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
        temporaryDirectory: NamedTemporaryDirectory
    ) throws -> SwiftDependencyAdmissionCoordinator {
        let configuration = SwiftDependencyShadowConfiguration(
            admittingManifestAt: temporaryDirectory.path.join("manifest.json").str,
            resultPath: temporaryDirectory.path.join("result.json").str,
            changedSourceIdentity: provider,
            pathMappings: []
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
        for _ in 0..<1_000 {
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
