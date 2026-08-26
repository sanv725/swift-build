//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT && SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT

import Testing

import SWBCore
import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SwiftDependencyCompatiblePlanPreflightTests {
    private let provider = "/^src/Provider.swift"
    private let bridge = "/^src/Bridge.swift"
    private let caller = "/^src/Caller.swift"
    private let unrelated = "/^src/Unrelated.swift"

    @Test
    func patchesACompatiblePlanAndCalculatesTheTransitiveConeBeforeAdmission() throws {
        let overlay = Path("/tmp/u02-prefix-map.json")
        let result = try SwiftDependencyCompatiblePlanPreflight.run(
            previousManifest: baselineManifest(),
            changedSourceIdentities: [provider],
            jobs: sources.map(job),
            overlayPath: overlay
        ) { job, commandLine in
            #expect(!commandLine.contains("-cache-compile-job"))
            #expect(commandLine.contains("-module-import-from-cas"))
            #expect(commandLine.suffix(2) == ["-vfsoverlay", overlay.str])
            #expect(!commandLine.contains("/old/overlay.json"))
            switch job.sourceIdentity {
            case provider:
                return providerProjection(fingerprint: "provider-v2")
            case bridge:
                return bridgeProjection(fingerprint: "bridge-v2")
            case caller:
                return callerProjection()
            default:
                Issue.record("preflight compiled an unrelated primary")
                return unrelatedProjection()
            }
        }

        #expect(result.executions.map(\.sourceIdentity) == [provider, bridge, caller])
        #expect(result.fixedPoint.invalidationCone.affectedSources
            == [provider, bridge, caller].sorted())
        #expect(result.fixedPoint.invalidationCone.reusableSources == [unrelated])
        #expect(result.fixedPoint.compilationCounts == [provider: 1, bridge: 1, caller: 1])
    }

    @Test
    func rejectsIncompleteOrDuplicatePlanCoverageWithoutCompiling() throws {
        let baseline = try baselineManifest()
        var compileCount = 0
        #expect(throws: (any Error).self) {
            try SwiftDependencyCompatiblePlanPreflight.run(
                previousManifest: baseline,
                changedSourceIdentities: [provider],
                jobs: Array(sources.dropLast()).map(job),
                overlayPath: Path("/tmp/u02-prefix-map.json")
            ) { _, _ in
                compileCount += 1
                return self.unrelatedProjection()
            }
        }
        #expect(compileCount == 0)

        #expect(throws: (any Error).self) {
            try SwiftDependencyCompatiblePlanPreflight.run(
                previousManifest: baseline,
                changedSourceIdentities: [provider],
                jobs: sources.map(job) + [job(provider)],
                overlayPath: Path("/tmp/u02-prefix-map.json")
            ) { _, _ in
                compileCount += 1
                return self.unrelatedProjection()
            }
        }
        #expect(compileCount == 0)
    }

    private var sources: [String] {
        [provider, bridge, caller, unrelated]
    }

    private func job(_ source: String) -> SwiftDependencyCompatiblePlanPreflight.Job {
        .init(
            sourceIdentity: source,
            commandLine: [
                "/usr/bin/swift-frontend",
                "-primary-file", source,
                "-emit-reference-dependencies-path", source + ".swiftdeps",
                "-cache-compile-job",
                "-vfsoverlay", "/old/overlay.json",
            ],
            dependencyOutputPath: Path(source + ".swiftdeps")
        )
    }

    private func baselineManifest() throws -> SwiftDependencyModuleManifest {
        try .init(
            moduleName: "PreflightFixture",
            toolchainIdentity: "toolchain-v1",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: sources,
            projectionsBySource: [
                provider: providerProjection(fingerprint: "provider-v1"),
                bridge: bridgeProjection(fingerprint: "bridge-v1"),
                caller: callerProjection(),
                unrelated: unrelatedProjection(),
            ]
        )
    }

    private func providerProjection(
        fingerprint: String
    ) -> SwiftDependencyFingerprintProjection {
        projection(
            fingerprint: fingerprint,
            definitions: [.init(key: key("provider"), fingerprint: nil)],
            uses: []
        )
    }

    private func bridgeProjection(
        fingerprint: String
    ) -> SwiftDependencyFingerprintProjection {
        projection(
            fingerprint: fingerprint,
            definitions: [.init(key: key("bridge"), fingerprint: nil)],
            uses: [key("provider")]
        )
    }

    private func callerProjection() -> SwiftDependencyFingerprintProjection {
        projection(
            fingerprint: "caller-v1",
            definitions: [],
            uses: [key("bridge")]
        )
    }

    private func unrelatedProjection() -> SwiftDependencyFingerprintProjection {
        projection(fingerprint: "unrelated-v1", definitions: [], uses: [])
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
