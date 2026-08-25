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
fileprivate struct SwiftDependencyShadowCoordinatorTests {
    private let provider = "/^src/Provider.swift"
    private let caller = "/^src/Caller.swift"
    private let unrelated = "/^src/Unrelated.swift"

    @Test
    func bodyEditReachesParityAndPersistsACompleteResult() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let coordinator = try makeCoordinator(
            temporaryDirectory: temporaryDirectory,
            changedSources: [provider]
        )
        let summary = try coordinator.observeProjection(
            providerProjection(fingerprint: "provider-v1"),
            sourceIdentity: provider,
            fs: localFS
        )
        let result = try readResult(temporaryDirectory: temporaryDirectory)

        #expect(summary.outcome == "parity")
        #expect(result.outcome == "parity")
        #expect(result.predictedAffectedSources == [provider])
        #expect(result.predictedReusableSources == [caller, unrelated])
        #expect(result.actualExecutedSources == [provider])
        #expect(result.pendingSources.isEmpty)
        #expect(result.missingActualExecutions.isEmpty)
        #expect(result.extraActualExecutions.isEmpty)
    }

    @Test
    func buffersCallerThatFinishesBeforeAnAPIChangingProvider() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let coordinator = try makeCoordinator(
            temporaryDirectory: temporaryDirectory,
            changedSources: [provider]
        )
        let earlyCaller = try coordinator.observeProjection(
            callerProjection(),
            sourceIdentity: caller,
            fs: localFS
        )
        #expect(earlyCaller.outcome == "pending")
        #expect(earlyCaller.pendingCount == 1)

        let providerFinished = try coordinator.observeProjection(
            providerProjection(fingerprint: "provider-v2"),
            sourceIdentity: provider,
            fs: localFS
        )
        let result = try readResult(temporaryDirectory: temporaryDirectory)
        #expect(providerFinished.outcome == "parity")
        #expect(result.predictedAffectedSources == [caller, provider])
        #expect(result.actualExecutedSources == [caller, provider])
        #expect(result.predictedCompilationCounts == [caller: 1, provider: 1])
        #expect(result.actualExecutionCounts == [caller: 1, provider: 1])
    }

    @Test
    func recordsExtraAppleExecutionAsMismatchWithoutChangingExecution() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let coordinator = try makeCoordinator(
            temporaryDirectory: temporaryDirectory,
            changedSources: [provider]
        )
        _ = try coordinator.observeProjection(
            providerProjection(fingerprint: "provider-v1"),
            sourceIdentity: provider,
            fs: localFS
        )
        let extra = try coordinator.observeProjection(
            unrelatedProjection(),
            sourceIdentity: unrelated,
            fs: localFS
        )
        let result = try readResult(temporaryDirectory: temporaryDirectory)

        #expect(extra.outcome == "mismatch")
        #expect(result.predictedAffectedSources == [provider])
        #expect(result.actualExecutedSources == [provider, unrelated])
        #expect(result.extraActualExecutions == [unrelated])
        #expect(result.missingActualExecutions.isEmpty)
    }

    @Test
    func loadsCanonicalConfigurationAndRejectsUnknownPrimary() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let manifest = try baselineManifest()
        let configuration = configuration(
            temporaryDirectory: temporaryDirectory,
            changedSources: [provider]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try localFS.write(
            Path(configuration.previousManifestPath),
            contents: ByteString(try encoder.encode(manifest)),
            atomically: true
        )
        let configurationPath = temporaryDirectory.path.join("shadow-config.json")
        try localFS.write(
            configurationPath,
            contents: ByteString(try encoder.encode(configuration)),
            atomically: true
        )
        let coordinator = try SwiftDependencyShadowCoordinator(
            configurationPath: configurationPath,
            fs: localFS
        )
        #expect(throws: (any Error).self) {
            try coordinator.observeProjection(
                unrelatedProjection(),
                sourceIdentity: "/^src/Unknown.swift",
                fs: localFS
            )
        }
    }

    @Test
    func recordsACompleteCanonicalBaselineInCompletionOrder() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let configuration = SwiftDependencyShadowConfiguration(
            recordingManifestAt: temporaryDirectory.path.join("recorded-manifest.json").str,
            resultPath: temporaryDirectory.path.join("shadow-result.json").str,
            moduleName: "ShadowFixture",
            toolchainIdentity: "toolchain-v1",
            pathPolicyIdentity: "portable-v1",
            sourceIdentities: [unrelated, provider, caller],
            pathMappings: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configurationPath = temporaryDirectory.path.join("record-config.json")
        try localFS.write(
            configurationPath,
            contents: ByteString(try encoder.encode(configuration)),
            atomically: true
        )
        let coordinator = try SwiftDependencyShadowCoordinator(
            configurationPath: configurationPath,
            fs: localFS
        )

        let first = try coordinator.observeProjection(
            callerProjection(),
            sourceIdentity: caller,
            fs: localFS
        )
        #expect(first.outcome == "collecting")
        #expect(first.pendingCount == 2)
        _ = try coordinator.observeProjection(
            unrelatedProjection(),
            sourceIdentity: unrelated,
            fs: localFS
        )
        let final = try coordinator.observeProjection(
            providerProjection(fingerprint: "provider-v1"),
            sourceIdentity: provider,
            fs: localFS
        )

        #expect(final.outcome == "recorded")
        #expect(final.pendingCount == 0)
        let manifestBytes = try localFS.read(
            temporaryDirectory.path.join("recorded-manifest.json")
        )
        let manifest = try JSONDecoder().decode(
            SwiftDependencyModuleManifest.self,
            from: Data(manifestBytes.bytes)
        )
        let expectedManifest = try baselineManifest()
        #expect(manifest == expectedManifest)
        let result = try readResult(temporaryDirectory: temporaryDirectory)
        #expect(result.outcome == "recorded")
        #expect(result.pendingSources.isEmpty)
        #expect(result.actualExecutedSources == [caller, provider, unrelated])
        #expect(result.moduleStructureIdentity == manifest.structureIdentity)
        #expect(result.currentDependencyIdentity == manifest.dependencyIdentity)
    }

    private func makeCoordinator(
        temporaryDirectory: NamedTemporaryDirectory,
        changedSources: [String]
    ) throws -> SwiftDependencyShadowCoordinator {
        try .init(
            configuration: configuration(
                temporaryDirectory: temporaryDirectory,
                changedSources: changedSources
            ),
            previousManifest: baselineManifest()
        )
    }

    private func configuration(
        temporaryDirectory: NamedTemporaryDirectory,
        changedSources: [String]
    ) -> SwiftDependencyShadowConfiguration {
        .init(
            previousManifestPath: temporaryDirectory.path.join("previous-manifest.json").str,
            resultPath: temporaryDirectory.path.join("shadow-result.json").str,
            changedSourceIdentities: changedSources,
            pathMappings: []
        )
    }

    private func readResult(
        temporaryDirectory: NamedTemporaryDirectory
    ) throws -> SwiftDependencyShadowResult {
        let bytes = try localFS.read(temporaryDirectory.path.join("shadow-result.json"))
        return try JSONDecoder().decode(
            SwiftDependencyShadowResult.self,
            from: Data(bytes.bytes)
        )
    }

    private func baselineManifest() throws -> SwiftDependencyModuleManifest {
        try .init(
            moduleName: "ShadowFixture",
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
