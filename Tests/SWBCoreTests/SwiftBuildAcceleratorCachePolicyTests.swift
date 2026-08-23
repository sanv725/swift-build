//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing

import SWBCore
import SWBUtil

@Suite
fileprivate struct SwiftBuildAcceleratorCachePolicyTests {
    @Test
    func externallySelectableModesAreFailSafe() {
        #expect(SwiftBuildAcceleratorCacheMode.externallySelectedMode("") == .stock)
        #expect(SwiftBuildAcceleratorCacheMode.externallySelectedMode("stock") == .stock)
        #expect(SwiftBuildAcceleratorCacheMode.externallySelectedMode("unknown") == .stock)
        #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
        #expect(SwiftBuildAcceleratorCacheMode.externallySelectedMode("trust") == .trust)
        #else
        #expect(SwiftBuildAcceleratorCacheMode.externallySelectedMode("trust") == .observe)
        #endif
        #expect(SwiftBuildAcceleratorCacheMode.externallySelectedMode(" observe\n") == .observe)
        #expect(SwiftBuildAcceleratorCacheMode.externallySelectedMode("VERIFY") == .verify)

        #expect(!SwiftBuildAcceleratorCacheMode.stock.isAcceleratorEnabled)
        #expect(SwiftBuildAcceleratorCacheMode.observe.isAcceleratorEnabled)
        #expect(SwiftBuildAcceleratorCacheMode.verify.isAcceleratorEnabled)
        #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
        #expect(SwiftBuildAcceleratorCacheMode.trust.isAcceleratorEnabled)
        #else
        #expect(!SwiftBuildAcceleratorCacheMode.trust.isAcceleratorEnabled)
        #endif

        #expect(!SwiftBuildAcceleratorCacheMode.stock.usesAcceleratorMaterialization)
        #expect(!SwiftBuildAcceleratorCacheMode.observe.usesAcceleratorMaterialization)
        #expect(SwiftBuildAcceleratorCacheMode.verify.usesAcceleratorMaterialization)
        #expect(SwiftBuildAcceleratorCacheMode.trust.usesAcceleratorMaterialization)
    }

    @Test
    func policyProbesOnlySelectableEligibleModes() {
        #expect(!SwiftBuildAcceleratorCachePolicy.stock.shouldProbe)
        #expect(SwiftBuildAcceleratorCachePolicy(mode: .observe, eligibility: .eligible).shouldProbe)
        #expect(SwiftBuildAcceleratorCachePolicy(mode: .verify, eligibility: .eligible).shouldProbe)
        #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
        #expect(SwiftBuildAcceleratorCachePolicy(mode: .trust, eligibility: .eligible).shouldProbe)
        #else
        #expect(!SwiftBuildAcceleratorCachePolicy(mode: .trust, eligibility: .eligible).shouldProbe)
        #endif
        #expect(!SwiftBuildAcceleratorCachePolicy(mode: .observe, eligibility: .excluded(.unsupportedPlatform)).shouldProbe)
    }

    @Test
    func policySerializationPreservesModeAndBoundedReason() throws {
        let values: [SwiftBuildAcceleratorCachePolicy] = [
            .stock,
            .init(mode: .observe, eligibility: .eligible),
            .init(mode: .verify, eligibility: .excluded(.unsupportedOutput)),
            .init(mode: .trust, eligibility: .excluded(.cacheUnavailable)),
        ]

        for value in values {
            let serializer = MsgPackSerializer()
            serializer.serialize(value)
            let deserializer = MsgPackDeserializer(serializer.byteString)
            let decoded: SwiftBuildAcceleratorCachePolicy = try deserializer.deserialize()
            #expect(decoded == value)
        }
    }

    #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
    @Test
    func replayOnlyScannerPathRequiresAnExplicitAbsoluteValue() throws {
        #expect(try SwiftModuleDependencyGraph.acceleratorReplayLibSwiftScanPath(environment: [:]) == nil)

        #expect(throws: (any Error).self) {
            try SwiftModuleDependencyGraph.acceleratorReplayLibSwiftScanPath(environment: [
                SwiftModuleDependencyGraph.acceleratorReplayLibSwiftScanEnvironmentKey: "",
            ])
        }
        #expect(throws: (any Error).self) {
            try SwiftModuleDependencyGraph.acceleratorReplayLibSwiftScanPath(environment: [
                SwiftModuleDependencyGraph.acceleratorReplayLibSwiftScanEnvironmentKey: "relative/libSwiftScan.dylib",
            ])
        }

        let absolutePath = try SwiftModuleDependencyGraph.acceleratorReplayLibSwiftScanPath(environment: [
            SwiftModuleDependencyGraph.acceleratorReplayLibSwiftScanEnvironmentKey: "/tmp/libSwiftScan.dylib",
        ])
        #expect(absolutePath == Path("/tmp/libSwiftScan.dylib"))
    }
    #endif
}
