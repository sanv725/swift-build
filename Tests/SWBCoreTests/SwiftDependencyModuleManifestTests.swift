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
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct SwiftDependencyModuleManifestTests {
    private static let providerIdentity = "/^src/Provider.swift"
    private static let callerIdentity = "/^src/Caller.swift"
    private static let unrelatedIdentity = "/^src/Unrelated.swift"
    private static let allSources = [providerIdentity, callerIdentity, unrelatedIdentity]

    private struct CompiledState {
        let manifest: SwiftDependencyModuleManifest
        let projections: [String: SwiftDependencyFingerprintProjection]
    }

    @Test
    func portableManifestDerivesExactBodyAndAPIInvalidationCones() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let sdkPath = try macOSSDKPath()
        let base = try compileState(
            root: temporaryDirectory.path.join("base"),
            sdkPath: sdkPath,
            providerSource: "public func callee(_ value: Int) -> Int { value + 1 }\n"
        )
        let portableCopy = try compileState(
            root: temporaryDirectory.path.join("portable-copy"),
            sdkPath: sdkPath,
            providerSource: "public func callee(_ value: Int) -> Int { value + 1 }\n"
        )
        let body = try compileState(
            root: temporaryDirectory.path.join("body"),
            sdkPath: sdkPath,
            providerSource: "public func callee(_ value: Int) -> Int { value + 2 }\n"
        )
        let api = try compileState(
            root: temporaryDirectory.path.join("api"),
            sdkPath: sdkPath,
            providerSource: "public func callee(_ value: Int, scale: Int = 1) -> Int { value * scale + 2 }\n"
        )

        #expect(base.manifest.structureIdentity == portableCopy.manifest.structureIdentity)
        #expect(base.manifest.dependencyIdentity == portableCopy.manifest.dependencyIdentity)
        #expect(base.manifest.structureIdentity == body.manifest.structureIdentity)
        #expect(base.manifest.structureIdentity == api.manifest.structureIdentity)
        #expect(base.manifest.dependencyIdentity == body.manifest.dependencyIdentity)
        #expect(base.manifest.dependencyIdentity != api.manifest.dependencyIdentity)

        let changedProvider: Set<String> = [Self.providerIdentity]
        let bodyCone = try #require(SwiftDependencyInvalidationCone.compare(
            previous: base.manifest,
            current: body.manifest,
            changedSourceIdentities: changedProvider
        ))
        #expect(bodyCone.affectedSources == [Self.providerIdentity])
        #expect(bodyCone.reusableSources == [Self.callerIdentity, Self.unrelatedIdentity])

        let apiCone = try #require(SwiftDependencyInvalidationCone.compare(
            previous: base.manifest,
            current: api.manifest,
            changedSourceIdentities: changedProvider
        ))
        #expect(apiCone.affectedSources == [Self.callerIdentity, Self.providerIdentity])
        #expect(apiCone.reusableSources == [Self.unrelatedIdentity])

        var bodyScheduler = try SwiftDependencyInvalidationScheduler(
            previousManifest: base.manifest,
            expectedSourceIdentities: Self.allSources,
            changedSourceIdentities: changedProvider
        )
        try bodyScheduler.recordCompiledProjection(
            body.projections[Self.providerIdentity]!,
            for: Self.providerIdentity
        )
        #expect(bodyScheduler.isComplete)
        let bodySchedulerResult = try bodyScheduler.result()
        #expect(bodySchedulerResult.invalidationCone == bodyCone)

        var apiScheduler = try SwiftDependencyInvalidationScheduler(
            previousManifest: base.manifest,
            expectedSourceIdentities: Self.allSources,
            changedSourceIdentities: changedProvider
        )
        try apiScheduler.recordCompiledProjection(
            api.projections[Self.providerIdentity]!,
            for: Self.providerIdentity
        )
        #expect(apiScheduler.pendingSourceIdentities == [Self.callerIdentity])
        try apiScheduler.recordCompiledProjection(
            api.projections[Self.callerIdentity]!,
            for: Self.callerIdentity
        )
        #expect(apiScheduler.isComplete)
        let apiSchedulerResult = try apiScheduler.result()
        #expect(apiSchedulerResult.invalidationCone == apiCone)
    }

    @Test
    func manifestRejectsIncompleteSetsAndTopologyChanges() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let state = try compileState(
            root: temporaryDirectory.path.join("complete"),
            sdkPath: try macOSSDKPath(),
            providerSource: "public func callee(_ value: Int) -> Int { value + 1 }\n"
        )
        var incomplete = state.projections
        incomplete.removeValue(forKey: Self.unrelatedIdentity)
        #expect(throws: (any Error).self) {
            try makeManifest(projections: incomplete, expectedSources: Self.allSources)
        }

        let twoSource = try makeManifest(
            projections: incomplete,
            expectedSources: [Self.providerIdentity, Self.callerIdentity]
        )
        #expect(twoSource.structureIdentity != state.manifest.structureIdentity)
        #expect(SwiftDependencyInvalidationCone.compare(
            previous: twoSource,
            current: state.manifest,
            changedSourceIdentities: []
        ) == nil)
    }

    @Test
    func pathMappingsUseLongestComponentBoundedPrefix() {
        let root = SwiftDependencyPathMapping(
            physicalPrefix: "/physical/root",
            virtualPrefix: "/^root"
        )
        let nested = SwiftDependencyPathMapping(
            physicalPrefix: "/physical/root/nested",
            virtualPrefix: "/^nested"
        )
        #expect(root.map("/physical/root") == "/^root")
        #expect(root.map("/physical/root/File.swift") == "/^root/File.swift")
        #expect(root.map("/physical/root-other/File.swift") == nil)

        let mappings = [root, nested]
        let selected = mappings.sorted {
            $0.physicalPrefix.utf8.count > $1.physicalPrefix.utf8.count
        }.lazy.compactMap { $0.map("/physical/root/nested/File.swift") }.first
        #expect(selected == "/^nested/File.swift")
    }

    private func compileState(root: Path, sdkPath: String, providerSource: String) throws -> CompiledState {
        try localFS.createDirectory(root, recursive: true)
        let physicalSources = [
            Self.providerIdentity: root.join("Provider.swift"),
            Self.callerIdentity: root.join("Caller.swift"),
            Self.unrelatedIdentity: root.join("Unrelated.swift"),
        ]
        try localFS.write(
            physicalSources[Self.providerIdentity]!,
            contents: ByteString(encodingAsUTF8: providerSource)
        )
        try localFS.write(
            physicalSources[Self.callerIdentity]!,
            contents: ByteString(
                encodingAsUTF8: "public func callSite(_ value: Int) -> Int { callee(value) }\n"
            )
        )
        try localFS.write(
            physicalSources[Self.unrelatedIdentity]!,
            contents: ByteString(
                encodingAsUTF8: "public func unrelated(_ value: Int) -> Int { value - 1 }\n"
            )
        )

        var projections: [String: SwiftDependencyFingerprintProjection] = [:]
        for sourceIdentity in Self.allSources {
            let primary = physicalSources[sourceIdentity]!
            let dependencies = root.join(primary.basenameWithoutSuffix + ".swiftdeps")
            let object = root.join(primary.basenameWithoutSuffix + ".o")
            try compile(
                primary: primary,
                secondary: Self.allSources.compactMap { identity in
                    identity == sourceIdentity ? nil : physicalSources[identity]
                },
                sdkPath: sdkPath,
                dependencies: dependencies,
                object: object
            )
            projections[sourceIdentity] = try SwiftDependencyFingerprintProjection.read(
                from: dependencies,
                sourceIdentity: sourceIdentity,
                pathMappings: [
                    .init(physicalPrefix: root.str, virtualPrefix: "/^state")
                ]
            )
        }
        return .init(
            manifest: try makeManifest(
                projections: projections,
                expectedSources: Self.allSources
            ),
            projections: projections
        )
    }

    private func makeManifest(
        projections: [String: SwiftDependencyFingerprintProjection],
        expectedSources: [String]
    ) throws -> SwiftDependencyModuleManifest {
        try .init(
            moduleName: "DependencyManifestFixture",
            toolchainIdentity: "xcode-26.3-swift-6.2.4",
            pathPolicyIdentity: "portable-dependency-paths-v1",
            expectedSourceIdentities: expectedSources,
            projectionsBySource: projections
        )
    }

    private func compile(
        primary: Path,
        secondary: [Path],
        sdkPath: String,
        dependencies: Path,
        object: Path
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "--sdk", "macosx",
            "swift-frontend",
            "-c",
            "-primary-file", primary.str,
        ] + secondary.map(\.str) + [
            "-module-name", "DependencyManifestFixture",
            "-sdk", sdkPath,
            "-emit-reference-dependencies-path", dependencies.str,
            "-o", object.str,
        ]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unknown swift-frontend failure"
            throw StubError.error(message)
        }
    }

    private func macOSSDKPath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unable to resolve macOS SDK"
            throw StubError.error(message)
        }
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else {
            throw StubError.error("xcrun returned an empty macOS SDK path")
        }
        return output
    }
}

#endif
