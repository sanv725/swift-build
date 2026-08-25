//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT

import Testing

@testable import SWBCore

@Suite
fileprivate struct SwiftDependencyInvalidationSchedulerTests {
    private let provider = "/^src/Provider.swift"
    private let bridge = "/^src/Bridge.swift"
    private let caller = "/^src/Caller.swift"
    private let unrelated = "/^src/Unrelated.swift"

    @Test
    func reachesATransitiveAPIFixedPointAndRetainsUnrelatedWork() throws {
        let baseline = try manifest(
            providerFingerprint: "provider-v1",
            bridgeFingerprint: "bridge-v1",
            callerFingerprint: "caller-v1"
        )
        var scheduler = try SwiftDependencyInvalidationScheduler(
            previousManifest: baseline,
            expectedSourceIdentities: sources,
            changedSourceIdentities: [provider]
        )

        #expect(scheduler.pendingSourceIdentities == [provider])
        try scheduler.recordCompiledProjection(
            providerProjection(fingerprint: "provider-v2"),
            for: provider
        )
        #expect(scheduler.pendingSourceIdentities == [bridge])
        try scheduler.recordCompiledProjection(
            bridgeProjection(fingerprint: "bridge-v2", providerName: "provider"),
            for: bridge
        )
        #expect(scheduler.pendingSourceIdentities == [caller])
        try scheduler.recordCompiledProjection(
            callerProjection(fingerprint: "caller-v1", bridgeName: "bridge"),
            for: caller
        )
        #expect(scheduler.isComplete)

        let result = try scheduler.result()
        #expect(result.invalidationCone.affectedSources == [bridge, caller, provider].sorted())
        #expect(result.invalidationCone.reusableSources == [unrelated])
        #expect(result.compilationCounts == [provider: 1, bridge: 1, caller: 1])
    }

    @Test
    func reenqueuesCallerCompiledBeforeItsChangedProvider() throws {
        let earlyCaller = "/^src/A-Caller.swift"
        let lateProvider = "/^src/Z-Provider.swift"
        let providerKey = key("late-provider")
        let callerProjection = projection(
            fingerprint: "caller-v1",
            definitions: [],
            uses: [providerKey]
        )
        let providerV1 = projection(
            fingerprint: "provider-v1",
            definitions: [.init(key: providerKey, fingerprint: nil)],
            uses: []
        )
        let baseline = try SwiftDependencyModuleManifest(
            moduleName: "OrderFixture",
            toolchainIdentity: "toolchain-v1",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: [earlyCaller, lateProvider],
            projectionsBySource: [earlyCaller: callerProjection, lateProvider: providerV1]
        )
        var scheduler = try SwiftDependencyInvalidationScheduler(
            previousManifest: baseline,
            expectedSourceIdentities: [earlyCaller, lateProvider],
            changedSourceIdentities: [earlyCaller, lateProvider]
        )

        #expect(scheduler.nextSourceIdentity == earlyCaller)
        try scheduler.recordCompiledProjection(callerProjection, for: earlyCaller)
        try scheduler.recordCompiledProjection(
            projection(
                fingerprint: "provider-v2",
                definitions: [.init(key: providerKey, fingerprint: nil)],
                uses: []
            ),
            for: lateProvider
        )
        #expect(scheduler.pendingSourceIdentities == [earlyCaller])
        try scheduler.recordCompiledProjection(callerProjection, for: earlyCaller)

        let result = try scheduler.result()
        #expect(result.compilationCounts == [earlyCaller: 2, lateProvider: 1])
        #expect(result.invalidationCone.affectedSources == [earlyCaller, lateProvider])
    }

    @Test
    func bodyEditStopsAfterOneCompileAndTopologyMismatchFailsClosed() throws {
        let baseline = try manifest(
            providerFingerprint: "provider-v1",
            bridgeFingerprint: "bridge-v1",
            callerFingerprint: "caller-v1"
        )
        var scheduler = try SwiftDependencyInvalidationScheduler(
            previousManifest: baseline,
            expectedSourceIdentities: sources,
            changedSourceIdentities: [provider]
        )
        try scheduler.recordCompiledProjection(
            providerProjection(fingerprint: "provider-v1"),
            for: provider
        )
        let result = try scheduler.result()
        #expect(result.invalidationCone.affectedSources == [provider])
        #expect(result.invalidationCone.reusableSources == [bridge, caller, unrelated].sorted())

        #expect(throws: (any Error).self) {
            try SwiftDependencyInvalidationScheduler(
                previousManifest: baseline,
                expectedSourceIdentities: Array(sources.dropLast()),
                changedSourceIdentities: [provider]
            )
        }
    }

    private var sources: [String] {
        [provider, bridge, caller, unrelated]
    }

    private func manifest(
        providerFingerprint: String,
        bridgeFingerprint: String,
        callerFingerprint: String
    ) throws -> SwiftDependencyModuleManifest {
        try SwiftDependencyModuleManifest(
            moduleName: "TransitiveFixture",
            toolchainIdentity: "toolchain-v1",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: sources,
            projectionsBySource: [
                provider: providerProjection(fingerprint: providerFingerprint),
                bridge: bridgeProjection(fingerprint: bridgeFingerprint, providerName: "provider"),
                caller: callerProjection(fingerprint: callerFingerprint, bridgeName: "bridge"),
                unrelated: projection(fingerprint: "unrelated-v1", definitions: [], uses: []),
            ]
        )
    }

    private func providerProjection(fingerprint: String) -> SwiftDependencyFingerprintProjection {
        projection(
            fingerprint: fingerprint,
            definitions: [.init(key: key("provider"), fingerprint: nil)],
            uses: []
        )
    }

    private func bridgeProjection(
        fingerprint: String,
        providerName: String
    ) -> SwiftDependencyFingerprintProjection {
        projection(
            fingerprint: fingerprint,
            definitions: [.init(key: key("bridge"), fingerprint: nil)],
            uses: [key(providerName)]
        )
    }

    private func callerProjection(
        fingerprint: String,
        bridgeName: String
    ) -> SwiftDependencyFingerprintProjection {
        projection(
            fingerprint: fingerprint,
            definitions: [],
            uses: [key(bridgeName)]
        )
    }

    private func projection(
        fingerprint: String,
        definitions: [SwiftDependencyFingerprintProjection.Definition],
        uses: [SwiftDependencyFingerprintProjection.Key]
    ) -> SwiftDependencyFingerprintProjection {
        .init(
            compilerVersion: "Swift version 6.2.4",
            sourceFileInterfaceFingerprint: fingerprint,
            providedInterfaces: definitions,
            dependedInterfaces: uses
        )
    }

    private func key(_ name: String) -> SwiftDependencyFingerprintProjection.Key {
        .init(kind: "top-level", aspect: "interface", context: nil, name: name)
    }
}

#endif
