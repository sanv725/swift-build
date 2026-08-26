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
fileprivate struct SwiftDependencyPriorGraphClosureTests {
    private let provider = "/^src/Provider.swift"
    private let bridge = "/^src/Bridge.swift"
    private let caller = "/^src/Caller.swift"
    private let unrelated = "/^src/Unrelated.swift"

    @Test
    func bodyStableProjectionStopsAtTheEditedSource() throws {
        let baseline = try manifest()
        let result = try SwiftDependencyPriorGraphClosure.calculate(
            previousManifest: baseline,
            changedProjections: [provider: providerProjection("provider-v1")]
        )
        #expect(result.changedProviderKeys.isEmpty)
        #expect(result.invalidationCone.affectedSources == [provider])
        #expect(result.invalidationCone.reusableSources == [bridge, caller, unrelated].sorted())
    }

    @Test
    func changedProviderTraversesThePriorReverseGraphConservatively() throws {
        let result = try SwiftDependencyPriorGraphClosure.calculate(
            previousManifest: manifest(),
            changedProjections: [provider: providerProjection("provider-v2")]
        )
        #expect(result.changedProviderKeys == [key("provider")])
        #expect(result.invalidationCone.affectedSources == [provider, bridge, caller].sorted())
        #expect(result.invalidationCone.reusableSources == [unrelated])
    }

    @Test
    func priorClosureMayOveradmitBeyondAStableIntermediateInterface() throws {
        let baseline = try manifest()
        let graph = try SwiftDependencyPriorGraphClosure.calculate(
            previousManifest: baseline,
            changedProjections: [provider: providerProjection("provider-v2")]
        )
        var serial = try SwiftDependencyInvalidationScheduler(
            previousManifest: baseline,
            expectedSourceIdentities: [provider, bridge, caller, unrelated],
            changedSourceIdentities: [provider]
        )
        try serial.recordCompiledProjection(providerProjection("provider-v2"), for: provider)
        try serial.recordCompiledProjection(
            projection(
                "bridge-v1",
                definitions: [.init(key: key("bridge"), fingerprint: nil)],
                uses: [key("provider")]
            ),
            for: bridge
        )
        let truth = try serial.result()

        #expect(truth.invalidationCone.affectedSources == [provider, bridge].sorted())
        #expect(graph.invalidationCone.affectedSources == [provider, bridge, caller].sorted())
        #expect(Set(truth.invalidationCone.affectedSources).isSubset(
            of: Set(graph.invalidationCone.affectedSources)
        ))
    }

    @Test
    func newProviderKeyInvalidatesAPriorUnresolvedUse() throws {
        let potential = key("potential-overload")
        let baseline = try SwiftDependencyModuleManifest(
            moduleName: "NewProviderFixture",
            toolchainIdentity: "toolchain-v1",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: [provider, caller],
            projectionsBySource: [
                provider: providerProjection("provider-v1"),
                caller: projection("caller-v1", definitions: [], uses: [potential]),
            ]
        )
        let changed = projection(
            "provider-v2",
            definitions: [
                .init(key: key("provider"), fingerprint: nil),
                .init(key: potential, fingerprint: "new-overload-v1"),
            ],
            uses: []
        )
        let result = try SwiftDependencyPriorGraphClosure.calculate(
            previousManifest: baseline,
            changedProjections: [provider: changed]
        )
        #expect(result.invalidationCone.affectedSources == [provider, caller].sorted())
    }

    @Test
    func rejectsUnknownSourcesAndCompilerDrift() throws {
        let baseline = try manifest()
        #expect(throws: (any Error).self) {
            try SwiftDependencyPriorGraphClosure.calculate(
                previousManifest: baseline,
                changedProjections: ["/^src/Missing.swift": providerProjection("v2")]
            )
        }
        let drifted = SwiftDependencyFingerprintProjection(
            compilerVersion: "Swift version 7",
            sourceFileInterfaceFingerprint: "provider-v2",
            providedInterfaces: [.init(key: key("provider"), fingerprint: nil)],
            dependedInterfaces: []
        )
        #expect(throws: (any Error).self) {
            try SwiftDependencyPriorGraphClosure.calculate(
                previousManifest: baseline,
                changedProjections: [provider: drifted]
            )
        }
    }

    private func manifest() throws -> SwiftDependencyModuleManifest {
        try SwiftDependencyModuleManifest(
            moduleName: "ClosureFixture",
            toolchainIdentity: "toolchain-v1",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: [provider, bridge, caller, unrelated],
            projectionsBySource: [
                provider: providerProjection("provider-v1"),
                bridge: projection(
                    "bridge-v1",
                    definitions: [.init(key: key("bridge"), fingerprint: nil)],
                    uses: [key("provider")]
                ),
                caller: projection(
                    "caller-v1", definitions: [], uses: [key("bridge")]
                ),
                unrelated: projection("unrelated-v1", definitions: [], uses: []),
            ]
        )
    }

    private func providerProjection(
        _ fingerprint: String
    ) -> SwiftDependencyFingerprintProjection {
        projection(
            fingerprint,
            definitions: [.init(key: key("provider"), fingerprint: nil)],
            uses: []
        )
    }

    private func projection(
        _ fingerprint: String,
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
