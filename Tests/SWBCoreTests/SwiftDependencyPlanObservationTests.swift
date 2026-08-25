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

@testable import SWBCore

@Suite
fileprivate struct SwiftDependencyPlanObservationTests {
    private let sources = ["/^src/A.swift", "/^src/B.swift", "/^src/U.swift"]
    private let planInputIdentity = String(repeating: "a", count: 64)

    @Test
    func observesCompatibleUnseenContentWithoutExecutingThePlan() throws {
        let baseline = try manifest(fingerprints: ["a1", "b1", "u1"])
        let unseenContent = try manifest(fingerprints: ["a2", "b1", "u1"])
        let jobs = plannedJobs()
        let binding = try SwiftDependencyPlanBinding(
            moduleManifest: baseline,
            planInputIdentity: planInputIdentity,
            jobs: jobs
        )
        let reordered = try SwiftDependencyPlanBinding(
            moduleManifest: baseline,
            planInputIdentity: planInputIdentity,
            jobs: Array(jobs.reversed())
        )

        #expect(binding == reordered)
        #expect(binding.lookupIdentity == reordered.lookupIdentity)
        #expect(binding.observe(
            currentManifest: unseenContent,
            currentPlanInputIdentity: planInputIdentity
        ) == .compatible(planStructureIdentity: binding.planStructureIdentity))
    }

    @Test
    func rejectsInputTopologyAndDecodedIntegrityMismatches() throws {
        let baseline = try manifest(fingerprints: ["a1", "b1", "u1"])
        let binding = try SwiftDependencyPlanBinding(
            moduleManifest: baseline,
            planInputIdentity: planInputIdentity,
            jobs: plannedJobs()
        )
        #expect(binding.observe(
            currentManifest: baseline,
            currentPlanInputIdentity: String(repeating: "b", count: 64)
        ) == .incompatible(.planInputs))

        let smaller = try SwiftDependencyModuleManifest(
            moduleName: "Fixture",
            toolchainIdentity: "xcode-26.3-swift-6.2.4",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: Array(sources.prefix(2)),
            projectionsBySource: Dictionary(uniqueKeysWithValues: zip(
                sources.prefix(2),
                [projection(fingerprint: "a1"), projection(fingerprint: "b1")]
            ))
        )
        #expect(binding.observe(
            currentManifest: smaller,
            currentPlanInputIdentity: planInputIdentity
        ) == .incompatible(.moduleStructure))

        let encoded = try JSONEncoder().encode(binding)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["planStructureIdentity"] = String(repeating: "0", count: 64)
        let corrupted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(SwiftDependencyPlanBinding.self, from: corrupted)
        #expect(decoded.observe(
            currentManifest: baseline,
            currentPlanInputIdentity: planInputIdentity
        ) == .incompatible(.integrity))
    }

    @Test
    func rejectsIncompleteDuplicateAndCyclicPlans() throws {
        let baseline = try manifest(fingerprints: ["a1", "b1", "u1"])
        #expect(throws: (any Error).self) {
            try SwiftDependencyPlanBinding(
                moduleManifest: baseline,
                planInputIdentity: planInputIdentity,
                jobs: plannedJobs().filter { $0.identity != "compile-u" }
            )
        }

        var duplicate = plannedJobs()
        duplicate.append(duplicate[0])
        #expect(throws: (any Error).self) {
            try SwiftDependencyPlanBinding(
                moduleManifest: baseline,
                planInputIdentity: planInputIdentity,
                jobs: duplicate
            )
        }

        let cyclic = [
            job("compile-a", source: sources[0], dependencies: ["compile-b"]),
            job("compile-b", source: sources[1], dependencies: ["compile-a"]),
            job("compile-u", source: sources[2]),
        ]
        #expect(throws: (any Error).self) {
            try SwiftDependencyPlanBinding(
                moduleManifest: baseline,
                planInputIdentity: planInputIdentity,
                jobs: cyclic
            )
        }
    }

    private func manifest(fingerprints: [String]) throws -> SwiftDependencyModuleManifest {
        try SwiftDependencyModuleManifest(
            moduleName: "Fixture",
            toolchainIdentity: "xcode-26.3-swift-6.2.4",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: sources,
            projectionsBySource: Dictionary(uniqueKeysWithValues: zip(
                sources,
                fingerprints.map { projection(fingerprint: $0) }
            ))
        )
    }

    private func projection(fingerprint: String) -> SwiftDependencyFingerprintProjection {
        .init(
            compilerVersion: "Swift version 6.2.4",
            sourceFileInterfaceFingerprint: fingerprint,
            providedInterfaces: [],
            dependedInterfaces: []
        )
    }

    private func plannedJobs() -> [SwiftDependencyPlanBinding.Job] {
        [
            job("compile-a", source: sources[0]),
            job("compile-b", source: sources[1], dependencies: ["compile-a"]),
            job("compile-u", source: sources[2]),
            job("emit-module", dependencies: ["compile-a", "compile-b", "compile-u"]),
        ]
    }

    private func job(
        _ identity: String,
        source: String? = nil,
        dependencies: [String] = []
    ) -> SwiftDependencyPlanBinding.Job {
        .init(
            identity: identity,
            primarySourceIdentity: source,
            dependencies: dependencies,
            commandShape: ["swift-frontend", source == nil ? "-emit-module" : "-c"],
            outputShape: ["object"]
        )
    }
}

#endif
