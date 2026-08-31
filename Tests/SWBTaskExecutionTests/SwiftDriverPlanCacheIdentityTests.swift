//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT

import Testing

import SWBTaskExecution

@Suite
fileprivate struct SwiftDriverPlanCacheIdentityTests {
    private let baseKey = String(repeating: "a", count: 64)

    @Test
    func aggregateDependenciesRequireTheExactReplayBoundary() {
        let root = "/tmp/driver-plan"
        var environment = [
            SwiftDriverAggregateDependencyReporting.environmentVariable: "1",
            "SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE": "replay",
            "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY_SCOPE": "driver",
            "SWIFT_BUILD_DRIVER_PLAN_CACHE_LIVE_CAS": "1",
            "SWIFT_BUILD_DRIVER_PLAN_CACHE_INVALIDATE_SOURCE": "/tmp/File.swift",
            "SWIFT_BUILD_DRIVER_PLAN_CACHE_ROOT": root,
            "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY": baseKey,
        ]
        #expect(
            SwiftDriverAggregateDependencyReporting.planRoot(
                environment: environment
            ) == root
        )
        environment["SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE"] = "record"
        #expect(
            SwiftDriverAggregateDependencyReporting.planRoot(
                environment: environment
            ) == nil
        )
        environment["SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE"] = "replay"
        environment["SWIFT_BUILD_DRIVER_PLAN_CACHE_INVALIDATE_SOURCE"] = nil
        #expect(
            SwiftDriverAggregateDependencyReporting.planRoot(
                environment: environment
            ) == nil
        )
    }

    @Test
    func legacyScopePreservesExternalKey() {
        #expect(
            SwiftDriverPlanCacheKeyScope.legacy.actionKey(
                baseKey: baseKey, driverIdentity: "Driver-A"
            ) == baseKey
        )
    }

    @Test
    func driverScopeIsStableAndSeparatesPlans() {
        let first = SwiftDriverPlanCacheKeyScope.driver.actionKey(
            baseKey: baseKey, driverIdentity: "Driver-A"
        )
        let repeatFirst = SwiftDriverPlanCacheKeyScope.driver.actionKey(
            baseKey: baseKey, driverIdentity: "Driver-A"
        )
        let second = SwiftDriverPlanCacheKeyScope.driver.actionKey(
            baseKey: baseKey, driverIdentity: "Driver-B"
        )
        #expect(first == repeatFirst)
        #expect(first.count == 64)
        #expect(first != baseKey)
        #expect(first != second)
    }

    @Test
    func driverScopeIdentityUsesDeterministicPlanInputs() {
        let first = swiftDriverPlanCacheScopeIdentity(
            moduleName: "Fixture", outputPrefix: "Fixture", variant: "normal",
            architecture: "arm64", ruleInfo: ["SwiftDriver", "Fixture"],
            commandLine: ["builtin-SwiftDriver", "--", "-module-name", "Fixture"]
        )
        let repeated = swiftDriverPlanCacheScopeIdentity(
            moduleName: "Fixture", outputPrefix: "Fixture", variant: "normal",
            architecture: "arm64", ruleInfo: ["SwiftDriver", "Fixture"],
            commandLine: ["builtin-SwiftDriver", "--", "-module-name", "Fixture"]
        )
        let changed = swiftDriverPlanCacheScopeIdentity(
            moduleName: "Fixture", outputPrefix: "Fixture", variant: "normal",
            architecture: "x86_64", ruleInfo: ["SwiftDriver", "Fixture"],
            commandLine: ["builtin-SwiftDriver", "--", "-module-name", "Fixture"]
        )
        #expect(first == repeated)
        #expect(first.count == 64)
        #expect(first != changed)
    }

    @Test
    func liveCASReferenceIsGenerationAndPathBound() throws {
        let reference = SwiftDriverPlanLiveCASReference(
            actionKey: baseKey, casPath: "/tmp/cas-a"
        )
        try reference.validate(actionKey: baseKey, casPath: "/tmp/cas-a")
        #expect(throws: (any Error).self) {
            try reference.validate(
                actionKey: String(repeating: "b", count: 64),
                casPath: "/tmp/cas-a"
            )
        }
        #expect(throws: (any Error).self) {
            try reference.validate(actionKey: baseKey, casPath: "/tmp/cas-b")
        }
    }
}

#endif
