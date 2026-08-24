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

import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SwiftJobCASTests {
    @Test
    func configurationRequiresAnAbsoluteRootAndKnownMode() {
        #expect(SwiftJobCASConfiguration.parse(environment: [:]) == nil)
        #expect(SwiftJobCASConfiguration.parse(environment: [
            SwiftJobCASConfiguration.rootVariable: "relative",
            SwiftJobCASConfiguration.modeVariable: "record",
        ]) == nil)
        #expect(SwiftJobCASConfiguration.parse(environment: [
            SwiftJobCASConfiguration.rootVariable: "/tmp/job-cas",
            SwiftJobCASConfiguration.modeVariable: "unknown",
        ]) == nil)
        #expect(SwiftJobCASConfiguration.parse(environment: [
            SwiftJobCASConfiguration.rootVariable: "/tmp/job-cas",
            SwiftJobCASConfiguration.modeVariable: "read-write",
        ]) == .init(root: Path("/tmp/job-cas"), mode: .readWrite))

        var environment = [
            SwiftJobCASConfiguration.rootVariable: "/tmp/job-cas",
            SwiftJobCASConfiguration.modeVariable: "replay",
            "RETAINED": "yes",
        ]
        SwiftJobCASConfiguration.removeControlVariables(from: &environment)
        #expect(environment == ["RETAINED": "yes"])
    }

    @Test
    func identityIsPortableAcrossOutputDirectoriesAndIgnoresModuleWideCompilerKeyDrift() {
        let first = identity(
            primaryInputDigests: ["/__swiftbuild_opt__/source/Leaf.swift=content-a"],
            compilerCacheKeys: ["llvmcas://module-a"]
        )
        let second = SwiftJobCASIdentity(
            toolchainIdentity: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
            ruleInfoType: "Compile",
            moduleName: "Fixture",
            primaryInputDigests: ["/__swiftbuild_opt__/source/Leaf.swift=content-a"],
            producerCompilerCacheKeys: ["llvmcas://module-b"],
            commandLine: ["swift-frontend", "-c", "/__swiftbuild_opt__/source/Leaf.swift"],
            outputNames: [Path("/different/physical/root/Leaf.o").basename, Path("/different/physical/root/Leaf.d").basename]
        )
        let mutated = identity(
            primaryInputDigests: ["/__swiftbuild_opt__/source/Leaf.swift=content-b"],
            compilerCacheKeys: ["llvmcas://module-b"]
        )

        #expect(first.key == second.key)
        #expect(first.key != mutated.key)
        #expect(first.key.count == 64)
        #expect(first.commandLineDigest.count == 64)
    }

    @Test
    func identityNormalizesSchedulerNumberedSupplementaryOutputMaps() {
        let first = SwiftJobCASIdentity(
            toolchainIdentity: "/toolchain/swift-frontend",
            ruleInfoType: "Compile",
            moduleName: "Fixture",
            primaryInputDigests: ["Leaf.swift=content"],
            producerCompilerCacheKeys: ["llvmcas://stable"],
            commandLine: [
                "swift-frontend", "-c", "Leaf.swift",
                "-supplementary-output-file-map", "/state/supplementaryOutputs-6",
                "-target", "arm64-apple-ios18.0-simulator",
            ],
            outputNames: ["Leaf.o"]
        )
        let second = SwiftJobCASIdentity(
            toolchainIdentity: "/toolchain/swift-frontend",
            ruleInfoType: "Compile",
            moduleName: "Fixture",
            primaryInputDigests: ["Leaf.swift=content"],
            producerCompilerCacheKeys: ["llvmcas://stable"],
            commandLine: [
                "swift-frontend", "-c", "Leaf.swift",
                "-supplementary-output-file-map", "/state/supplementaryOutputs-19",
                "-target", "arm64-apple-ios18.0-simulator",
            ],
            outputNames: ["Leaf.o"]
        )

        #expect(first == second)
        #expect(first.commandLine[4] == "<supplementary-output-file-map>")
        #expect(!first.commandLine.joined().contains("supplementaryOutputs-6"))
    }

    @Test
    func identityNormalizesModuleWideClangIncludeTreeTokens() {
        let first = SwiftJobCASIdentity(
            toolchainIdentity: "/toolchain/swift-frontend",
            ruleInfoType: "Compile",
            moduleName: "Fixture",
            primaryInputDigests: ["Leaf.swift=content"],
            producerCompilerCacheKeys: ["llvmcas://module-a"],
            commandLine: [
                "swift-frontend", "-primary-file", "Leaf.swift",
                "-clang-include-tree-filelist", "llvmcas://tree-a",
                "-target", "arm64-apple-ios18.0-simulator",
            ],
            outputNames: ["Leaf.o"]
        )
        let second = SwiftJobCASIdentity(
            toolchainIdentity: "/toolchain/swift-frontend",
            ruleInfoType: "Compile",
            moduleName: "Fixture",
            primaryInputDigests: ["Leaf.swift=content"],
            producerCompilerCacheKeys: ["llvmcas://module-b"],
            commandLine: [
                "swift-frontend", "-primary-file", "Leaf.swift",
                "-clang-include-tree-filelist", "llvmcas://tree-b",
                "-target", "arm64-apple-ios18.0-simulator",
            ],
            outputNames: ["Leaf.o"]
        )

        #expect(first.key == second.key)
        #expect(first.commandLine[4] == "<clang-include-tree-filelist>")
    }

    @Test
    func derivesPrimaryInputContentIdentity() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let first = temporaryDirectory.path.join("First.swift")
        let second = temporaryDirectory.path.join("Second.swift")
        try localFS.write(first, contents: ByteString(encodingAsUTF8: "let first = 1\n"))
        try localFS.write(second, contents: ByteString(encodingAsUTF8: "let second = 2\n"))

        let digests = try SwiftJobCASIdentity.primaryInputDigests(
            commandLine: [
                "swift-frontend", "-c", "NonPrimary.swift",
                "-primary-file", first.str,
                "-primary-file", second.str,
            ],
            fs: localFS
        )
        #expect(digests?.count == 2)
        #expect(digests?[0].hasPrefix(first.str + "=") == true)
        #expect(digests?[1].hasPrefix(second.str + "=") == true)
        #expect(try SwiftJobCASIdentity.primaryInputDigests(
            commandLine: ["swift-frontend", "-c", first.str],
            fs: localFS
        ) == nil)

        let virtual = try SwiftJobCASIdentity.primaryInputDigests(
            commandLine: ["swift-frontend", "-primary-file", "/^src/First.swift"],
            workingDirectory: temporaryDirectory.path,
            fs: localFS
        )
        #expect(virtual?.count == 1)
        #expect(virtual?[0].hasPrefix("/^src/First.swift=") == true)
    }

    @Test
    func recordsAndReplaysACompleteOutputSet() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let root = temporaryDirectory.path.join("job-cas")
        let producer = temporaryDirectory.path.join("producer")
        let consumer = temporaryDirectory.path.join("consumer")
        let producerOutputs = [producer.join("Leaf.o"), producer.join("Leaf.d")]
        let consumerOutputs = [consumer.join("Leaf.o"), consumer.join("Leaf.d")]
        try localFS.createDirectory(producer, recursive: true)
        try localFS.write(producerOutputs[0], contents: ByteString(encodingAsUTF8: "object-v1"))
        try localFS.write(producerOutputs[1], contents: ByteString(encodingAsUTF8: "dependencies-v1"))

        let store = SwiftJobCASStore(root: root)
        let identity = identity(primaryInputDigests: ["Leaf.swift=content-v1"])
        let firstRecord = try store.record(identity: identity, outputs: producerOutputs, fs: localFS)
        #expect(firstRecord.outputCount == 2)
        #expect(firstRecord.outputBytes == 24)
        #expect(firstRecord.newBlobCount == 2)
        #expect(firstRecord.actionCreated)

        let replay = store.replay(identity: identity, destinations: consumerOutputs, fs: localFS)
        #expect(replay == .hit(outputCount: 2, outputBytes: 24))
        #expect(try localFS.read(consumerOutputs[0]) == ByteString(encodingAsUTF8: "object-v1"))
        #expect(try localFS.read(consumerOutputs[1]) == ByteString(encodingAsUTF8: "dependencies-v1"))

        let repeatedRecord = try store.record(identity: identity, outputs: producerOutputs, fs: localFS)
        #expect(repeatedRecord.newBlobCount == 0)
        #expect(!repeatedRecord.actionCreated)
        #expect(store.replay(
            identity: self.identity(primaryInputDigests: ["Leaf.swift=content-v2"]),
            destinations: consumerOutputs,
            fs: localFS
        ) == .miss)
    }

    @Test
    func rejectsCorruptContentBeforePublishingAnyDestination() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let root = temporaryDirectory.path.join("job-cas")
        let producer = temporaryDirectory.path.join("producer")
        let consumer = temporaryDirectory.path.join("consumer")
        let producerOutputs = [producer.join("Leaf.o"), producer.join("Leaf.d")]
        let consumerOutputs = [consumer.join("Leaf.o"), consumer.join("Leaf.d")]
        let object = ByteString(encodingAsUTF8: "object-v1")
        try localFS.createDirectory(producer, recursive: true)
        try localFS.write(producerOutputs[0], contents: object)
        try localFS.write(producerOutputs[1], contents: ByteString(encodingAsUTF8: "dependencies-v1"))

        let store = SwiftJobCASStore(root: root)
        let identity = identity(primaryInputDigests: ["Leaf.swift=content-v1"])
        _ = try store.record(identity: identity, outputs: producerOutputs, fs: localFS)
        let digest = SwiftJobCASIdentity.digest(bytes: object)
        let blob = root.join("blobs").join(String(digest.prefix(2))).join(digest)
        try localFS.write(blob, contents: ByteString(encodingAsUTF8: "corrupt"), atomically: true)

        guard case .invalid = store.replay(identity: identity, destinations: consumerOutputs, fs: localFS) else {
            Issue.record("corrupt content unexpectedly replayed")
            return
        }
        #expect(!localFS.exists(consumerOutputs[0]))
        #expect(!localFS.exists(consumerOutputs[1]))
    }

    @Test
    func writesMachineReadableMetricsEvents() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let store = SwiftJobCASStore(root: temporaryDirectory.path.join("job-cas"))
        try store.recordEvent(.init(
            jobKey: String(repeating: "a", count: 64),
            operation: "replay",
            outcome: "hit",
            durationNS: 123,
            outputCount: 2,
            outputBytes: 24
        ), fs: localFS)

        let events = try localFS.listdir(store.root.join("events"))
        #expect(events.count == 1)
        let payload = try localFS.read(store.root.join("events").join(events[0])).asString
        #expect(payload.contains("\"schema\":\"swift-build-job-cas-event-v1\""))
        #expect(payload.contains("\"outcome\":\"hit\""))
        #expect(payload.contains("\"durationNS\":123"))
    }

    private func identity(
        primaryInputDigests: [String],
        compilerCacheKeys: [String] = ["llvmcas://producer-diagnostic"]
    ) -> SwiftJobCASIdentity {
        .init(
            toolchainIdentity: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
            ruleInfoType: "Compile",
            moduleName: "Fixture",
            primaryInputDigests: primaryInputDigests,
            producerCompilerCacheKeys: compilerCacheKeys,
            commandLine: ["swift-frontend", "-c", "/__swiftbuild_opt__/source/Leaf.swift"],
            outputNames: ["Leaf.o", "Leaf.d"]
        )
    }
}

#endif
