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
fileprivate struct SwiftDependencyProjectionCASTests {
    private let sourceIdentity = "/^src/Provider.swift"

    @Test
    func configurationRequiresAnAbsoluteRootAndKnownMode() {
        #expect(SwiftDependencyProjectionCASConfiguration.parse(environment: [:]) == nil)
        #expect(SwiftDependencyProjectionCASConfiguration.parse(environment: [
            SwiftDependencyProjectionCASConfiguration.rootVariable: "relative",
            SwiftDependencyProjectionCASConfiguration.modeVariable: "record",
        ]) == nil)
        #expect(SwiftDependencyProjectionCASConfiguration.parse(environment: [
            SwiftDependencyProjectionCASConfiguration.rootVariable: "/tmp/projection-cas",
            SwiftDependencyProjectionCASConfiguration.modeVariable: "unknown",
        ]) == nil)
        #expect(SwiftDependencyProjectionCASConfiguration.parse(environment: [
            SwiftDependencyProjectionCASConfiguration.rootVariable: "/tmp/projection-cas",
            SwiftDependencyProjectionCASConfiguration.modeVariable: "read-write",
        ]) == .init(root: Path("/tmp/projection-cas"), mode: .readWrite))

        var environment = [
            SwiftDependencyProjectionCASConfiguration.rootVariable: "/tmp/projection-cas",
            SwiftDependencyProjectionCASConfiguration.modeVariable: "replay",
            "RETAINED": "yes",
        ]
        SwiftDependencyProjectionCASConfiguration.removeControlVariables(from: &environment)
        #expect(environment == ["RETAINED": "yes"])
    }

    @Test
    func identityIsPortableAcrossPhysicalRoots() throws {
        let manifest = try baselineManifest()
        let first = identity(
            manifest: manifest,
            physicalRoot: "/Users/first/Fixture",
            sourceDigest: "source-v2"
        )
        let second = identity(
            manifest: manifest,
            physicalRoot: "/Volumes/runner/Fixture",
            sourceDigest: "source-v2"
        )

        #expect(first.key == second.key)
        #expect(first.commandLine == second.commandLine)
        #expect(first.commandLine.contains("/^src/Provider.swift"))
        #expect(first.commandLine.contains("<emit-reference-dependencies-path>"))
        #expect(first.commandLine.contains("<vfsoverlay>"))
        #expect(first.key.count == 64)
    }

    @Test
    func normalizationUsesLongestPrefixesAndFirstDuplicateForEveryArgument() {
        let normalized = SwiftDependencyProjectionCASIdentity.normalizedCommandLine(
            [
                "/runner/project/Provider.swift",
                "/runner/project/Derived/Provider.swiftdeps",
            ],
            pathReplacements: [
                (physical: "/runner", virtual: "/^workspace"),
                (physical: "/runner/project", virtual: "/^src"),
                (physical: "/runner/project", virtual: "/^duplicate"),
            ]
        )

        #expect(normalized == [
            "/^src/Provider.swift",
            "/^src/Derived/Provider.swiftdeps",
        ])
    }

    @Test
    func identityChangesForEverySemanticInputFamily() throws {
        let manifest = try baselineManifest()
        let baseline = identity(
            manifest: manifest,
            physicalRoot: "/Users/first/Fixture",
            sourceDigest: "source-v2"
        )
        let sourceMutation = identity(
            manifest: manifest,
            physicalRoot: "/Users/first/Fixture",
            sourceDigest: "source-v3"
        )
        let dependencyMutation = identity(
            manifest: try baselineManifest(providerFingerprint: "provider-v0"),
            physicalRoot: "/Users/first/Fixture",
            sourceDigest: "source-v2"
        )
        let commandMutation = identity(
            manifest: manifest,
            physicalRoot: "/Users/first/Fixture",
            sourceDigest: "source-v2",
            importedModuleCAS: "llvmcas://module-v2"
        )

        #expect(baseline.key != sourceMutation.key)
        #expect(baseline.key != dependencyMutation.key)
        #expect(baseline.key != commandMutation.key)
    }

    @Test
    func recordsAndReplaysAnImmutableProjectionAction() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let store = SwiftDependencyProjectionCASStore(
            root: temporaryDirectory.path.join("projection-cas")
        )
        let identity = identity(
            manifest: try baselineManifest(),
            physicalRoot: "/Users/first/Fixture",
            sourceDigest: "source-v2"
        )
        let projection = providerProjection(fingerprint: "provider-v2")

        #expect(store.replay(identity: identity, fs: localFS) == .miss)
        let recorded = try store.record(
            identity: identity,
            projection: projection,
            fs: localFS
        )
        #expect(recorded.actionCreated)
        #expect(recorded.bytes > 0)
        #expect(store.replay(identity: identity, fs: localFS)
            == .hit(projection, bytes: recorded.bytes))

        let repeated = try store.record(
            identity: identity,
            projection: projection,
            fs: localFS
        )
        #expect(!repeated.actionCreated)
        #expect(repeated.bytes == recorded.bytes)

        let actionPath = store.root
            .join("actions")
            .join(String(identity.key.prefix(2)))
            .join("\(identity.key).json")
        try localFS.write(
            actionPath,
            contents: ByteString(encodingAsUTF8: "corrupt"),
            atomically: true
        )
        guard case .invalid = store.replay(identity: identity, fs: localFS) else {
            Issue.record("corrupt projection action unexpectedly replayed")
            return
        }
        #expect(throws: (any Error).self) {
            try store.record(identity: identity, projection: projection, fs: localFS)
        }
    }

    private func identity(
        manifest: SwiftDependencyModuleManifest,
        physicalRoot: String,
        sourceDigest: String,
        importedModuleCAS: String = "llvmcas://module-v1"
    ) -> SwiftDependencyProjectionCASIdentity {
        .init(
            sourceIdentity: sourceIdentity,
            sourceDigest: sourceDigest,
            previousManifest: manifest,
            commandLine: [
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                "-typecheck",
                "-primary-file", physicalRoot + "/Provider.swift",
                "-emit-reference-dependencies-path", physicalRoot + "/Derived/Provider.swiftdeps",
                "-vfsoverlay", physicalRoot + "/Derived/prefix-map.json",
                "-cas-path", physicalRoot + "/CAS",
                "-module-file", "FixtureDependency=\(importedModuleCAS)",
            ],
            pathReplacements: [(physical: physicalRoot, virtual: "/^src")]
        )
    }

    private func baselineManifest(
        providerFingerprint: String = "provider-v1"
    ) throws -> SwiftDependencyModuleManifest {
        try .init(
            moduleName: "ProjectionCASFixture",
            toolchainIdentity: "toolchain-v1",
            pathPolicyIdentity: "portable-v1",
            expectedSourceIdentities: [sourceIdentity],
            projectionsBySource: [
                sourceIdentity: providerProjection(fingerprint: providerFingerprint),
            ]
        )
    }

    private func providerProjection(
        fingerprint: String
    ) -> SwiftDependencyFingerprintProjection {
        .init(
            compilerVersion: "Swift version 6.2.4",
            sourceFileInterfaceFingerprint: fingerprint,
            providedInterfaces: [
                .init(
                    key: .init(
                        kind: "top-level",
                        aspect: "interface",
                        context: nil,
                        name: "provider"
                    ),
                    fingerprint: nil
                ),
            ],
            dependedInterfaces: []
        )
    }
}

#endif
