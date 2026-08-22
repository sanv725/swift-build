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
import SWBTestSupport
import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SwiftCacheOperationsTests {
    @Test
    func probeRequiresEveryKeyAndMaterializedOutput() throws {
        let operations = TestSwiftCacheOperations(
            queries: ["one": .hit(1), "two": .hit(2)],
            outputs: [
                1: [.init(kindName: "object", isMaterialized: true)],
                2: [
                    .init(kindName: "swiftmodule", isMaterialized: true),
                    .init(kindName: "dependencies", isMaterialized: true),
                ],
            ]
        )

        switch try SwiftDriverJobTaskAction.probeCache(
            operations: operations,
            cacheKeys: ["one", "two"],
            expectedOutputKindGroups: [["object"], ["swiftmodule", "dependencies"]]
        ) {
        case .hit(let compilations, let outputCount):
            #expect(compilations == [1, 2])
            #expect(outputCount == 3)
        case .miss:
            Issue.record("complete multi-key cache entry was reported as a miss")
        }
        #expect(operations.queriedKeys == ["one", "two"])

        operations.resetCalls()
        operations.queries["two"] = .miss
        switch try SwiftDriverJobTaskAction.probeCache(
            operations: operations,
            cacheKeys: ["one", "two"],
            expectedOutputKindGroups: [["object"], ["swiftmodule", "dependencies"]]
        ) {
        case .hit:
            Issue.record("missing second key was reported as a hit")
        case .miss(let reason):
            #expect(reason == .missingKey)
        }
        #expect(operations.queriedKeys == ["one", "two"])

        operations.resetCalls()
        operations.queries["two"] = .hit(2)
        operations.outputs[2] = [.init(kindName: "swiftmodule", isMaterialized: false)]
        switch try SwiftDriverJobTaskAction.probeCache(
            operations: operations,
            cacheKeys: ["one", "two"],
            expectedOutputKindGroups: [["object"], ["swiftmodule"]]
        ) {
        case .hit:
            Issue.record("nonmaterialized output was reported as a hit")
        case .miss(let reason):
            #expect(reason == .nonMaterializedOutput)
        }

        operations.resetCalls()
        switch try SwiftDriverJobTaskAction.probeCache(
            operations: operations,
            cacheKeys: [],
            expectedOutputKindGroups: []
        ) {
        case .hit:
            Issue.record("empty key list was reported as a hit")
        case .miss(let reason):
            #expect(reason == .missingKey)
        }
        #expect(operations.queriedKeys.isEmpty)
    }

    @Test
    func probeRequiresExactSupportedCachedOutputShape() throws {
        func missReason(
            outputs: [SwiftCacheCachedOutput],
            expectedOutputKindGroups: [[String]] = [["object", "dependencies"]]
        ) throws -> SwiftCacheProbeMissReason? {
            let operations = TestSwiftCacheOperations(
                queries: ["key": .hit(1)],
                outputs: [1: outputs]
            )
            switch try SwiftDriverJobTaskAction.probeCache(
                operations: operations,
                cacheKeys: ["key"],
                expectedOutputKindGroups: expectedOutputKindGroups
            ) {
            case .hit:
                return nil
            case .miss(let reason):
                return reason
            }
        }

        #expect(try missReason(outputs: [
            .init(kindName: "object", isMaterialized: true),
            .init(kindName: "dependencies", isMaterialized: true),
            .init(kindName: "cached-diagnostics", isMaterialized: true),
        ]) == nil)
        #expect(try missReason(outputs: [
            .init(kindName: "dependencies", isMaterialized: true),
            .init(kindName: "object", isMaterialized: true),
        ]) == .unsupportedOutput)
        #expect(try missReason(outputs: [
            .init(kindName: "object", isMaterialized: true),
        ]) == .unsupportedOutput)
        #expect(try missReason(outputs: [
            .init(kindName: "object", isMaterialized: true),
            .init(kindName: "dependencies", isMaterialized: true),
            .init(kindName: "unknown-future-output", isMaterialized: true),
        ]) == .unsupportedOutput)
        #expect(try missReason(outputs: [
            .init(kindName: "cached-diagnostics", isMaterialized: true),
            .init(kindName: "object", isMaterialized: true),
            .init(kindName: "dependencies", isMaterialized: true),
        ]) == .unsupportedOutput)
        #expect(try missReason(outputs: [
            .init(kindName: "object", isMaterialized: true),
            .init(kindName: "dependencies", isMaterialized: true),
            .init(kindName: "cached-diagnostics", isMaterialized: true),
            .init(kindName: "cached-diagnostics", isMaterialized: true),
        ]) == .unsupportedOutput)
        #expect(try missReason(
            outputs: [.init(kindName: "object", isMaterialized: true)],
            expectedOutputKindGroups: [["unknown-planned-output"]]
        ) == .unsupportedOutput)

        let misalignedOperations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        switch try SwiftDriverJobTaskAction.probeCache(
            operations: misalignedOperations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: []
        ) {
        case .hit:
            Issue.record("misaligned key/output groups reached replay")
        case .miss(let reason):
            #expect(reason == .unsupportedOutput)
        }
        #expect(misalignedOperations.queriedKeys.isEmpty)
    }

    @Test
    func semanticOutputAdapterIsAbsentFromNormalBinaries() throws {
        let profiles: [(SwiftCacheSemanticOutputJobKind, Int, [String], [SwiftCacheCachedOutput], Int)] = [
            (
                .compile,
                10,
                ["object", "d", "const-values", "swift-dependencies", "diagnostics"],
                [
                    .init(kindName: "object", isMaterialized: true),
                    .init(kindName: "dependencies", isMaterialized: true),
                    .init(kindName: "swift-dependencies", isMaterialized: true),
                    .init(kindName: "const-values", isMaterialized: true),
                ],
                5
            ),
            (
                .emitModule,
                1,
                [
                    "swiftmodule", "swiftdoc", "swiftsourceinfo",
                    "emit-module-diagnostics", "emit-module.d", "abi-baseline-json",
                ],
                [
                    .init(kindName: "dependencies", isMaterialized: true),
                    .init(kindName: "swiftmodule", isMaterialized: true),
                    .init(kindName: "swiftdoc", isMaterialized: true),
                    .init(kindName: "swiftsourceinfo", isMaterialized: true),
                    .init(kindName: "abi-baseline-json", isMaterialized: true),
                    .init(kindName: "cached-diagnostics", isMaterialized: true),
                ],
                6
            ),
        ]

        for (jobKind, keyCount, plannedKinds, cachedOutputs, expectedCount) in profiles {
            let cacheKeys = (0..<keyCount).map { "key-\($0)" }
            let queries: [String: TestSwiftCacheOperations.Query] = Dictionary(
                uniqueKeysWithValues: cacheKeys.enumerated().map { ($0.element, .hit($0.offset)) }
            )
            let outputs = Dictionary(
                uniqueKeysWithValues: (0..<keyCount).map { ($0, cachedOutputs) }
            )
            let operations = TestSwiftCacheOperations(
                queries: queries,
                outputs: outputs
            )
            switch try SwiftDriverJobTaskAction.probeCache(
                operations: operations,
                cacheKeys: cacheKeys,
                expectedOutputKindGroups: Array(repeating: plannedKinds, count: keyCount),
                semanticOutputJobKind: jobKind,
                allowUnsafeSemanticOutputAdapter: true
            ) {
            #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
            case .hit(let compilations, let outputCount):
                #expect(compilations == Array(0..<keyCount))
                #expect(outputCount == expectedCount * keyCount)
            case .miss:
                Issue.record("compile-gated semantic output profile was rejected")
            #else
            case .hit:
                Issue.record("normal binary admitted a compile-gated semantic output profile")
            case .miss(let reason):
                #expect(reason == .unsupportedOutput)
                #expect(operations.queriedKeys.isEmpty)
            #endif
            }
        }
    }

    @Test
    func unsupportedCachedOutputShapeNeverReplaysOrScrubs() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let output = temporaryDirectory.path.join("main.o")
        try fs.write(output, contents: ByteString(encodingAsUTF8: "frontend-owned"))
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "swiftmodule", isMaterialized: true)]]
        )
        operations.replaySideEffect = { _ in
            Issue.record("unsupported cache output shape reached replay")
        }

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(preparation.outcome == .unsupportedOutput)
        #expect(preparation.scrubSucceeded == nil)
        #expect(operations.replayedCompilations.isEmpty)
        #expect(try fs.read(output).asString == "frontend-owned")

        operations.resetCalls()
        let extraPlannedOutput = temporaryDirectory.path.join("unexpected.swiftmodule")
        let countMismatch = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output, extraPlannedOutput],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        #expect(countMismatch.outcome == .unsupportedOutput)
        #expect(operations.queriedKeys.isEmpty)
        #expect(operations.replayedCompilations.isEmpty)
        #expect(try fs.read(output).asString == "frontend-owned")
    }

    @Test
    func probeAndReplayErrorsPropagateToTheFailOpenDecisionBoundary() throws {
        let operations = TestSwiftCacheOperations(
            queries: ["one": .failure, "two": .hit(2)],
            outputs: [2: [.init(kindName: "object", isMaterialized: true)]]
        )
        #expect(throws: TestCacheError.self) {
            try SwiftDriverJobTaskAction.probeCache(
                operations: operations,
                cacheKeys: ["one", "two"],
                expectedOutputKindGroups: [["object"], ["object"]]
            )
        }
        #expect(operations.queriedKeys == ["one"])

        operations.resetCalls()
        operations.failReplayForCompilation = 2
        #expect(throws: TestCacheError.self) {
            try SwiftDriverJobTaskAction.replayCache(
                operations: operations,
                compilations: [1, 2, 3],
                commandLine: ["swift-frontend", "-c", "input.swift"]
            )
        }
        #expect(operations.replayCommandLine == ["-c", "input.swift"])
        #expect(operations.replayedCompilations == [1, 2])
    }

    @Test
    func replayCollectsCachedStreamsInCompilerKeyOrder() throws {
        let operations = TestSwiftCacheOperations(
            queries: [:],
            outputs: [:],
            replayStreamsByCompilation: [
                1: .init(standardOutput: "stdout-1", standardError: "stderr-1"),
                2: .init(standardOutput: "stdout-2", standardError: "stderr-2"),
                3: .init(standardOutput: "stdout-3", standardError: "stderr-3"),
            ]
        )

        let streams = try SwiftDriverJobTaskAction.replayCache(
            operations: operations,
            compilations: [3, 1, 2],
            commandLine: ["swift-frontend", "-frontend", "-c"],
            captureStreams: true
        )

        #expect(operations.replayCommandLine == ["-frontend", "-c"])
        #expect(operations.replayedCompilations == [3, 1, 2])
        #expect(streams?.map(\.standardOutput) == ["stdout-3", "stdout-1", "stdout-2"])
        #expect(streams?.map(\.standardError) == ["stderr-3", "stderr-1", "stderr-2"])
    }

    @Test
    func outputManifestDetectsContentCountAndMissingOutput() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let first = temporaryDirectory.path.join("first.o")
        let second = temporaryDirectory.path.join("module.swiftmodule")
        try fs.write(first, contents: ByteString(encodingAsUTF8: "first"))
        try fs.write(second, contents: ByteString(encodingAsUTF8: "second"))
        try fs.setFilePermissions(first, permissions: 0o600)
        try fs.setFilePermissions(second, permissions: 0o640)

        let baseline = try SwiftDriverJobTaskAction.makeOutputManifest([first, second], fs: fs)
        #expect(baseline.entries.map(\.ordinal) == [0, 1])
        #expect(baseline.entries.map(\.fileKind) == [.regularFile, .regularFile])
        #expect(baseline.entries.map(\.permissions) == [0o600, 0o640])
        #expect(baseline.entries.map(\.byteCount) == [5, 6])
        #expect(baseline.totalBytes == 11)
        #expect(baseline.mismatchCount(comparedTo: baseline) == 0)

        try fs.write(second, contents: ByteString(encodingAsUTF8: "changed"))
        let contentMismatch = try SwiftDriverJobTaskAction.makeOutputManifest([first, second], fs: fs)
        #expect(baseline.mismatchCount(comparedTo: contentMismatch) == 1)

        let countMismatch = try SwiftDriverJobTaskAction.makeOutputManifest([first], fs: fs)
        #expect(baseline.mismatchCount(comparedTo: countMismatch) == 1)

        try fs.write(second, contents: ByteString(encodingAsUTF8: "second"))
        try fs.setFilePermissions(second, permissions: 0o600)
        let modeMismatch = try SwiftDriverJobTaskAction.makeOutputManifest([first, second], fs: fs)
        #expect(baseline.mismatchCount(comparedTo: modeMismatch) == 1)

        do {
            _ = try SwiftDriverJobTaskAction.makeOutputManifest([first, temporaryDirectory.path.join("missing")], fs: fs)
            Issue.record("missing output did not fail manifesting")
        } catch let error as SwiftCacheOutputError {
            #expect(error == .missingOutput)
        }
    }

    @Test
    func outputValidationRejectsUnsafeDestinations() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let file = temporaryDirectory.path.join("file.o")
        let directory = temporaryDirectory.path.join("directory")
        let symlink = temporaryDirectory.path.join("link")
        try fs.write(file, contents: ByteString(encodingAsUTF8: "object"))
        try fs.createDirectory(directory, recursive: true)
        try fs.symlink(symlink, target: file)

        try SwiftDriverJobTaskAction.validateOutputDestinations([file, temporaryDirectory.path.join("not-written-yet")], fs: fs)
        for paths in [[], [file, file], [Path("relative.o")], [directory], [symlink]] {
            do {
                try SwiftDriverJobTaskAction.validateOutputDestinations(paths, fs: fs)
                Issue.record("unsafe output destination was accepted: \(paths)")
            } catch let error as SwiftCacheOutputError {
                #expect(error == .unsupportedOutput)
            }
        }
    }

    #if canImport(Darwin)
    @Test
    func descriptorAdmissionRejectsAncestorSymlinkBeforeQueryOrScrub() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let realParent = temporaryDirectory.path.join("real-parent")
        let linkedParent = temporaryDirectory.path.join("linked-parent")
        let victim = realParent.join("main.o")
        try fs.createDirectory(realParent)
        try fs.write(victim, contents: ByteString(encodingAsUTF8: "victim"))
        try fs.symlink(linkedParent, target: realParent)
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [linkedParent.join("main.o")],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(preparation.outcome == .unsupportedOutput)
        #expect(operations.queriedKeys.isEmpty)
        #expect(operations.replayedCompilations.isEmpty)
        #expect(try fs.read(victim).asString == "victim")
    }

    @Test
    func descriptorAdmissionCancellationDuringAncestorWalkDoesNotQueryOrReplay() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let parent = temporaryDirectory.path.join("first").join("second")
        try localFS.createDirectory(parent, recursive: true)
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        var cancellationChecks = 0

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [parent.join("main.o")],
            commandLine: ["swift-frontend", "-c"],
            fs: localFS,
            isCancelled: {
                cancellationChecks += 1
                return cancellationChecks == 5
            }
        )

        #expect(preparation.outcome == .cancelled)
        #expect(cancellationChecks == 5)
        #expect(operations.queriedKeys.isEmpty)
        #expect(operations.replayedCompilations.isEmpty)
    }

    @Test
    func descriptorSessionPreservesLeafCreatedAfterAdmissionBeforeQuery() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let output = temporaryDirectory.path.join("main.o")
        let plan: SwiftCacheOutputAccessPlan
        switch try makeLocalFileSystemOutputAccessPlan(paths: [output], fs: localFS) {
        case .descriptor(let descriptorPlan):
            plan = descriptorPlan
        case .compatibilityFallback, .unsupportedFileSystem:
            Issue.record("local Darwin filesystem did not select the descriptor backend")
            return
        }
        try localFS.write(output, contents: ByteString(encodingAsUTF8: "new-owner"))
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        var quarantineCount = 0

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: localFS,
            outputAccessPlan: plan,
            quarantineCache: { quarantineCount += 1 }
        )

        #expect(preparation.outcome == .scrubFailure)
        #expect(!preparation.outcome.shouldExecuteFrontend)
        #expect(preparation.scrubSucceeded == false)
        #expect(operations.queriedKeys.isEmpty)
        #expect(operations.replayedCompilations.isEmpty)
        #expect(try localFS.read(output).asString == "new-owner")
        #expect(quarantineCount == 1)
    }

    @Test
    func cacheMissRejectsReplacementOfAnAdmittedLeaf() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let output = temporaryDirectory.path.join("main.o")
        let movedOutput = temporaryDirectory.path.join("moved-main.o")
        try localFS.write(output, contents: ByteString(encodingAsUTF8: "admitted"))
        let plan: SwiftCacheOutputAccessPlan
        switch try makeLocalFileSystemOutputAccessPlan(paths: [output], fs: localFS) {
        case .descriptor(let descriptorPlan):
            plan = descriptorPlan
        case .compatibilityFallback, .unsupportedFileSystem:
            Issue.record("local Darwin filesystem did not select the descriptor backend")
            return
        }
        let operations = TestSwiftCacheOperations(queries: ["key": .miss], outputs: [:])
        operations.querySideEffect = { _ in
            try localFS.move(output, to: movedOutput)
            try localFS.write(output, contents: ByteString(encodingAsUTF8: "new-owner"))
        }
        var quarantineCount = 0

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: localFS,
            outputAccessPlan: plan,
            quarantineCache: { quarantineCount += 1 }
        )

        #expect(preparation.outcome == .scrubFailure)
        #expect(preparation.scrubSucceeded == false)
        #expect(operations.queriedKeys == ["key"])
        #expect(operations.replayedCompilations.isEmpty)
        #expect(try localFS.read(output).asString == "new-owner")
        #expect(try localFS.read(movedOutput).asString == "admitted")
        #expect(quarantineCount == 1)
    }

    @Test
    func suppliedDescriptorPlanRequiresMaterializingLocalFileSystem() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let output = temporaryDirectory.path.join("main.o")
        let plan: SwiftCacheOutputAccessPlan
        switch try makeLocalFileSystemOutputAccessPlan(paths: [output], fs: localFS) {
        case .descriptor(let descriptorPlan):
            plan = descriptorPlan
        case .compatibilityFallback, .unsupportedFileSystem:
            Issue.record("local Darwin filesystem did not select the descriptor backend")
            return
        }

        for (mode, fs): (SwiftBuildAcceleratorCacheMode, any FSProxy) in [
            (.observe, localFS),
            (.verify, PseudoFS()),
        ] {
            let operations = TestSwiftCacheOperations(
                queries: ["key": .hit(1)],
                outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
            )
            let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
                mode: mode,
                operations: operations,
                cacheKeys: ["key"],
                expectedOutputKindGroups: [["object"]],
                plannedOutputs: [output],
                commandLine: ["swift-frontend", "-c"],
                fs: fs,
                outputAccessPlan: plan
            )

            #expect(preparation.outcome == .unsupportedOutput)
            #expect(operations.queriedKeys.isEmpty)
            #expect(operations.replayedCompilations.isEmpty)
        }
    }

    @Test
    func replayUsesPinnedParentAndNamespaceReplacementFailsBeforeFrontend() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let parent = temporaryDirectory.path.join("parent")
        let movedParent = temporaryDirectory.path.join("moved-parent")
        let output = parent.join("main.o")
        let movedOutput = movedParent.join("main.o")
        try fs.createDirectory(parent)
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        operations.replaySideEffect = { _ in
            try fs.write(output, contents: ByteString(encodingAsUTF8: "cached"))
            try fs.move(parent, to: movedParent)
            try fs.createDirectory(parent)
            try fs.write(output, contents: ByteString(encodingAsUTF8: "replacement-owner"))
        }
        var quarantineCount = 0

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            quarantineCache: { quarantineCount += 1 }
        )

        #expect(preparation.outcome == .scrubFailure)
        #expect(!preparation.outcome.shouldExecuteFrontend)
        #expect(preparation.scrubSucceeded == false)
        #expect(preparation.shadowManifest == nil)
        #expect(operations.queriedKeys == ["key"])
        #expect(operations.replayedCompilations == [1])
        #expect(!fs.exists(movedOutput), "the replayed node under the pinned parent must be scrubbed")
        #expect(try fs.read(output).asString == "replacement-owner")
        #expect(quarantineCount == 1)
    }

    @Test
    func postMaterializationReplacementIsPreservedAndFailsScrub() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let output = temporaryDirectory.path.join("main.o")
        let movedOutput = temporaryDirectory.path.join("moved-main.o")
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        operations.replaySideEffect = { _ in
            try localFS.write(output, contents: ByteString(encodingAsUTF8: "replayed"))
        }

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: localFS,
            pauseAtCancellationCheckpoint: { checkpoint in
                guard checkpoint == .postMaterialization else { return }
                try localFS.move(output, to: movedOutput)
                try localFS.write(output, contents: ByteString(encodingAsUTF8: "new-owner"))
            }
        )

        #expect(preparation.outcome == .scrubFailure)
        #expect(preparation.scrubSucceeded == false)
        #expect(operations.replayedCompilations == [1])
        #expect(try localFS.read(output).asString == "new-owner")
        #expect(try localFS.read(movedOutput).asString == "replayed")
    }

    @Test
    func freshDescriptorComparisonPreservesCallbackCancellation() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let output = temporaryDirectory.path.join("main.o")
        let plan: SwiftCacheOutputAccessPlan
        switch try makeLocalFileSystemOutputAccessPlan(paths: [output], fs: localFS) {
        case .descriptor(let descriptorPlan):
            plan = descriptorPlan
        case .compatibilityFallback, .unsupportedFileSystem:
            Issue.record("local Darwin filesystem did not select the descriptor backend")
            return
        }
        try localFS.write(output, contents: ByteString(encodingAsUTF8: "fresh"))
        let shadowManifest = try SwiftDriverJobTaskAction.makeOutputManifest([output], fs: localFS)
        let comparison = try SwiftDriverJobTaskAction.compareFreshOutputs(
            shadowManifest: shadowManifest,
            outputAccessPlan: plan
        )
        #expect(comparison.isMatch)

        #expect(throws: CancellationError.self) {
            _ = try SwiftDriverJobTaskAction.compareFreshOutputs(
                shadowManifest: shadowManifest,
                outputAccessPlan: plan,
                isCancelled: { true }
            )
        }
        #expect(localFS.exists(output))
    }
    #endif

    @Test
    func pseudoFileSystemCompatibilityFallbackReplaysManifestsAndScrubs() throws {
        let fs = PseudoFS()
        let output = Path("/main.o")
        switch try makeLocalFileSystemOutputAccessPlan(paths: [output], fs: fs) {
        case .compatibilityFallback:
            break
        #if canImport(Darwin)
        case .descriptor:
            Issue.record("PseudoFS unexpectedly selected the descriptor backend")
        #endif
        case .unsupportedFileSystem:
            Issue.record("PseudoFS unexpectedly failed compatibility admission")
        }
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        operations.replaySideEffect = { _ in
            try fs.write(output, contents: ByteString(encodingAsUTF8: "cached-object"))
            try fs.setFilePermissions(output, permissions: 0o600)
        }

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(preparation.outcome == .verificationReady)
        #expect(preparation.shadowManifest?.entries.map(\.permissions) == [0o600])
        #expect(preparation.shadowManifest?.entries.map(\.byteCount) == [13])
        #expect(preparation.scrubSucceeded == true)
        #expect(operations.queriedKeys == ["key"])
        #expect(operations.replayedCompilations == [1])
        #expect(!fs.exists(output))
    }

    @Test
    func pseudoFileSystemCompatibilityAdmissionRejectsDirectoryBeforeQuery() throws {
        let fs = PseudoFS()
        let output = Path("/directory")
        try fs.createDirectory(output)
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(preparation.outcome == .unsupportedOutput)
        #expect(operations.queriedKeys.isEmpty)
        #expect(operations.replayedCompilations.isEmpty)
        #expect(fs.isDirectory(output))
    }

    @Test
    func verifyDetectsSharedObjectiveCHeaderOutputBeforeReplay() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let object = temporaryDirectory.path.join("Feature.o")
        let sharedHeader = temporaryDirectory.path.join("App-Swift.h")

        #expect(SwiftDriverJobTaskAction.hasSharedObjectiveCHeaderOutput(
            commandLine: ["swift-frontend", "-c", "-emit-objc-header-path", sharedHeader.str],
            plannedOutputs: [object, sharedHeader]
        ))
        #expect(!SwiftDriverJobTaskAction.hasSharedObjectiveCHeaderOutput(
            commandLine: ["swift-frontend", "-c", "-emit-objc-header-path", sharedHeader.str],
            plannedOutputs: [object]
        ))
        #expect(!SwiftDriverJobTaskAction.hasSharedObjectiveCHeaderOutput(
            commandLine: ["swift-frontend", "-c", "-emit-objc-header-path", "relative/App-Swift.h"],
            plannedOutputs: [object, Path("relative/App-Swift.h")]
        ))
        #expect(!SwiftDriverJobTaskAction.hasSharedObjectiveCHeaderOutput(
            commandLine: ["swift-frontend", "-c", "-emit-objc-header-path"],
            plannedOutputs: [object, sharedHeader]
        ))

        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [object, sharedHeader],
            commandLine: ["swift-frontend", "-c", "-emit-objc-header-path", sharedHeader.str],
            fs: localFS
        )
        #expect(preparation.outcome == .unsupportedOutput)
        #expect(preparation.outcome.shouldExecuteFrontend)
        #expect(operations.queriedKeys.isEmpty)
        #expect(operations.replayedCompilations.isEmpty)
    }

    @Test
    func scrubRemovesTheCompletePlannedOutputList() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let replayed = temporaryDirectory.path.join("replayed.o")
        let partiallyWritten = temporaryDirectory.path.join("partial.swiftmodule")
        let absent = temporaryDirectory.path.join("never-written.d")
        try fs.write(replayed, contents: ByteString(encodingAsUTF8: "cached"))
        try fs.write(partiallyWritten, contents: ByteString(encodingAsUTF8: "partial"))

        try SwiftDriverJobTaskAction.scrubOutputs([replayed, partiallyWritten, absent], fs: fs)

        #expect(!fs.exists(replayed))
        #expect(!fs.exists(partiallyWritten))
        #expect(!fs.exists(absent))
    }

    @Test
    func stalePlannedOutputCannotMasqueradeAsReplayOutput() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let output = temporaryDirectory.path.join("main.o")
        try fs.write(output, contents: ByteString(encodingAsUTF8: "stale-preexisting-object"))
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(preparation.outcome == .manifestError)
        #expect(preparation.shadowManifest == nil)
        #expect(preparation.scrubSucceeded == true)
        #expect(operations.replayedCompilations == [1])
        #expect(!fs.exists(output))
    }

    @Test
    func verificationManifestRejectsPermissionModeMismatch() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let output = temporaryDirectory.path.join("main.o")
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        operations.replaySideEffect = { _ in
            try fs.write(output, contents: ByteString(encodingAsUTF8: "same-bytes"))
            try fs.setFilePermissions(output, permissions: 0o600)
        }

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        let shadowManifest = try #require(preparation.shadowManifest)
        #expect(shadowManifest.entries.map(\.permissions) == [0o600])

        try fs.write(output, contents: ByteString(encodingAsUTF8: "same-bytes"))
        try fs.setFilePermissions(output, permissions: 0o644)
        let comparison = SwiftDriverJobTaskAction.compareFreshOutputs(
            shadowManifest: shadowManifest,
            plannedOutputs: [output],
            fs: fs
        )
        #expect(!comparison.isMatch)
        #expect(comparison.mismatchCount == 1)
        #expect(comparison.comparedBytes == 10)
    }

    @Test
    func observeNeverReplaysAndVerifyPreparesThenScrubsShadowOutputs() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let output = temporaryDirectory.path.join("main.o")
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        operations.replaySideEffect = { _ in
            try fs.write(output, contents: ByteString(encodingAsUTF8: "cached-object"))
        }

        let observed = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .observe,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        #expect(observed.outcome == .wouldHit)
        #expect(observed.outcome.shouldExecuteFrontend)
        #expect(observed.cachedOutputCount == 1)
        #expect(observed.shadowManifest == nil)
        #expect(operations.replayedCompilations.isEmpty)

        let externallyRequestedTrust = SwiftBuildAcceleratorCacheMode.externallySelectedMode("trust")
        let trustPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: externallyRequestedTrust,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
        #expect(externallyRequestedTrust == .trust)
        #expect(trustPreparation.outcome == .unsafeTrustHit)
        #expect(!trustPreparation.outcome.shouldExecuteFrontend)
        #expect(operations.replayedCompilations == [1])
        #expect(try fs.read(output).asString == "cached-object")
        #else
        #expect(externallyRequestedTrust == .observe)
        #expect(trustPreparation.outcome == .wouldHit)
        #expect(trustPreparation.outcome.shouldExecuteFrontend)
        #expect(operations.replayedCompilations.isEmpty)
        #endif
        #expect(trustPreparation.shadowManifest == nil)

        operations.resetCalls()
        let verified = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        #expect(verified.outcome == .verificationReady)
        #expect(verified.outcome.shouldExecuteFrontend)
        #expect(verified.shadowManifest?.entries.count == 1)
        #expect(verified.replayStreams == nil)
        #expect(verified.scrubSucceeded == true)
        #expect(operations.replayedCompilations == [1])
        #expect(!fs.exists(output))

        try fs.write(output, contents: ByteString(encodingAsUTF8: "cached-object"))
        let match = SwiftDriverJobTaskAction.compareFreshOutputs(
            shadowManifest: try #require(verified.shadowManifest),
            plannedOutputs: [output],
            fs: fs
        )
        #expect(match.isMatch)
        #expect(match.mismatchCount == 0)
        #expect(fs.exists(output), "fresh compiler output must remain authoritative after comparison")

        try fs.write(output, contents: ByteString(encodingAsUTF8: "fresh-different-object"))
        let mismatch = SwiftDriverJobTaskAction.compareFreshOutputs(
            shadowManifest: try #require(verified.shadowManifest),
            plannedOutputs: [output],
            fs: fs
        )
        #expect(!mismatch.isMatch)
        #expect(mismatch.mismatchCount == 1)
        #expect(try fs.read(output).asString == "fresh-different-object")
    }

    @Test
    func directTrustWithoutAuthorizationDoesNotTouchCacheOrOutputs() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let output = temporaryDirectory.path.join("main.o")
        try fs.write(output, contents: ByteString(encodingAsUTF8: "fresh-frontend-owned"))
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]],
            replayStreams: .init(standardOutput: "cached-stdout", standardError: "cached-stderr")
        )
        operations.replaySideEffect = { _ in
            try fs.write(output, contents: ByteString(encodingAsUTF8: "cached-object"))
        }

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
        #expect(preparation.outcome == .unsafeTrustHit)
        #expect(!preparation.outcome.shouldExecuteFrontend)
        #expect(preparation.replayDurationNS != nil)
        #expect(preparation.scrubDurationNS != nil)
        #expect(preparation.scrubSucceeded == nil)
        #expect(operations.queriedKeys == ["key"])
        #expect(operations.replayedCompilations == [1])
        #expect(try fs.read(output).asString == "cached-object")
        #expect(preparation.replayStreams == [
            .init(standardOutput: "cached-stdout", standardError: "cached-stderr")
        ])
        #expect(SwiftDriverJobTaskAction.shouldAcceptUnsafeTrustHit(mode: .trust, outcome: preparation.outcome))
        #else
        #expect(preparation.outcome == .unauthorizedTrust)
        #expect(preparation.outcome.shouldExecuteFrontend)
        #expect(preparation.lookupDurationNS == 0)
        #expect(preparation.replayDurationNS == nil)
        #expect(preparation.scrubDurationNS == nil)
        #expect(operations.queriedKeys.isEmpty)
        #expect(operations.replayedCompilations.isEmpty)
        #expect(try fs.read(output).asString == "fresh-frontend-owned")
        #expect(!SwiftDriverJobTaskAction.cachePreparationIsFatal(.unauthorizedTrust, strictCASErrors: true))
        #expect(!SwiftDriverJobTaskAction.shouldAcceptUnsafeTrustHit(mode: .trust, outcome: .unsafeTrustHit))
        #endif
    }

    #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
    @Test
    func unsafeSemanticOutputProfilesRequireExactPinnedShapes() throws {
        let compilePlannedKinds = ["object", "d", "const-values", "swift-dependencies", "diagnostics"]
        let modulePlannedKinds = [
            "swiftmodule", "swiftdoc", "swiftsourceinfo",
            "emit-module-diagnostics", "emit-module.d", "abi-baseline-json",
        ]

        func probe(
            jobKind: SwiftCacheSemanticOutputJobKind,
            plannedKindGroups: [[String]],
            cachedOutputGroups: [[SwiftCacheCachedOutput]],
            allowAdapter: Bool = true
        ) throws -> (SwiftCacheProbeResult<Int>, [String]) {
            let cacheKeys = plannedKindGroups.indices.map { "key-\($0)" }
            let queries: [String: TestSwiftCacheOperations.Query] = Dictionary(
                uniqueKeysWithValues: cacheKeys.enumerated().map { ($0.element, .hit($0.offset)) }
            )
            let outputs = Dictionary(uniqueKeysWithValues: cachedOutputGroups.enumerated().map { ($0.offset, $0.element) })
            let operations = TestSwiftCacheOperations(
                queries: queries,
                outputs: outputs
            )
            let result = try SwiftDriverJobTaskAction.probeCache(
                operations: operations,
                cacheKeys: cacheKeys,
                expectedOutputKindGroups: plannedKindGroups,
                semanticOutputJobKind: jobKind,
                allowUnsafeSemanticOutputAdapter: allowAdapter
            )
            return (result, operations.queriedKeys)
        }

        let compileCachedOutputs: [SwiftCacheCachedOutput] = [
            .init(kindName: "object", isMaterialized: true),
            .init(kindName: "dependencies", isMaterialized: true),
            .init(kindName: "swift-dependencies", isMaterialized: true),
            .init(kindName: "const-values", isMaterialized: true),
        ]
        for keyCount in [10, 11] {
            let result = try probe(
                jobKind: .compile,
                plannedKindGroups: Array(repeating: compilePlannedKinds, count: keyCount),
                cachedOutputGroups: Array(repeating: compileCachedOutputs, count: keyCount)
            ).0
            switch result {
            case .hit(let compilations, let outputCount):
                #expect(compilations == Array(0..<keyCount))
                #expect(outputCount == 5 * keyCount)
            case .miss:
                Issue.record("exact \(keyCount)-key compile semantic output profile was rejected")
            }
        }

        let moduleCachedOutputs: [SwiftCacheCachedOutput] = [
            .init(kindName: "dependencies", isMaterialized: true),
            .init(kindName: "swiftmodule", isMaterialized: true),
            .init(kindName: "swiftdoc", isMaterialized: true),
            .init(kindName: "swiftsourceinfo", isMaterialized: true),
            .init(kindName: "abi-baseline-json", isMaterialized: true),
            .init(kindName: "cached-diagnostics", isMaterialized: true),
        ]
        switch try probe(
            jobKind: .emitModule,
            plannedKindGroups: [modulePlannedKinds],
            cachedOutputGroups: [moduleCachedOutputs]
        ).0 {
        case .hit(let compilations, let outputCount):
            #expect(compilations == [0])
            #expect(outputCount == 6)
        case .miss:
            Issue.record("exact module semantic output profile was rejected")
        }

        let rejectedCachedShapes: [(SwiftCacheSemanticOutputJobKind, Int, [String], [SwiftCacheCachedOutput])] = [
            (.compile, 10, compilePlannedKinds, compileCachedOutputs + [.init(kindName: "cached-diagnostics", isMaterialized: true)]),
            (.compile, 10, compilePlannedKinds, Array(compileCachedOutputs.dropLast())),
            (.compile, 10, compilePlannedKinds, [compileCachedOutputs[1], compileCachedOutputs[0]] + compileCachedOutputs.dropFirst(2)),
            (.emitModule, 1, modulePlannedKinds, Array(moduleCachedOutputs.dropLast())),
            (.emitModule, 1, modulePlannedKinds, [moduleCachedOutputs[1], moduleCachedOutputs[0]] + moduleCachedOutputs.dropFirst(2)),
            (.compile, 10, Array(compilePlannedKinds.dropLast()), compileCachedOutputs),
        ]
        for (jobKind, keyCount, plannedKinds, cachedOutputs) in rejectedCachedShapes {
            switch try probe(
                jobKind: jobKind,
                plannedKindGroups: Array(repeating: plannedKinds, count: keyCount),
                cachedOutputGroups: Array(repeating: cachedOutputs, count: keyCount)
            ).0 {
            case .hit:
                Issue.record("malformed semantic output profile was accepted")
            case .miss(let reason):
                #expect(reason == .unsupportedOutput)
            }
        }

        switch try probe(
            jobKind: .compile,
            plannedKindGroups: Array(repeating: compilePlannedKinds, count: 10),
            cachedOutputGroups: Array(repeating: compileCachedOutputs, count: 10),
            allowAdapter: false
        ).0 {
        case .hit:
            Issue.record("compile profile bypassed the explicit adapter boundary")
        case .miss(let reason):
            #expect(reason == .unsupportedOutput)
        }

        let wholeJobRejections: [(SwiftCacheSemanticOutputJobKind, [[String]], [[SwiftCacheCachedOutput]])] = [
            (.compile, [compilePlannedKinds], [compileCachedOutputs]),
            (.emitModule, Array(repeating: modulePlannedKinds, count: 2), Array(repeating: moduleCachedOutputs, count: 2)),
            (
                .compile,
                Array(repeating: compilePlannedKinds, count: 9) + [modulePlannedKinds],
                Array(repeating: compileCachedOutputs, count: 9) + [moduleCachedOutputs]
            ),
            (.emitModule, [compilePlannedKinds], [compileCachedOutputs]),
        ]
        for (jobKind, plannedKindGroups, cachedOutputGroups) in wholeJobRejections {
            let (result, queriedKeys) = try probe(
                jobKind: jobKind,
                plannedKindGroups: plannedKindGroups,
                cachedOutputGroups: cachedOutputGroups
            )
            switch result {
            case .hit:
                Issue.record("invalid whole-job semantic profile was accepted")
            case .miss(let reason):
                #expect(reason == .unsupportedOutput)
                #expect(queriedKeys.isEmpty)
            }
        }
    }

    @Test
    func unsafeTrustSemanticCompileProfileStillRequiresEveryPlannedFile() throws {
        let fs = PseudoFS()
        try fs.createDirectory(Path("/build"), recursive: true)
        let plannedKinds = ["object", "d", "const-values", "swift-dependencies", "diagnostics"]
        let cachedOutputs: [SwiftCacheCachedOutput] = [
            .init(kindName: "object", isMaterialized: true),
            .init(kindName: "dependencies", isMaterialized: true),
            .init(kindName: "swift-dependencies", isMaterialized: true),
            .init(kindName: "const-values", isMaterialized: true),
        ]
        let cacheKeys = (0..<10).map { "key-\($0)" }
        let outputGroups = (0..<10).map { index in
            [
                Path("/build/main-\(index).o"),
                Path("/build/main-\(index).d"),
                Path("/build/main-\(index).swiftconstvalues"),
                Path("/build/main-\(index).swiftdeps"),
                Path("/build/main-\(index).dia"),
            ]
        }
        let outputs = outputGroups.flatMap { $0 }
        let queries: [String: TestSwiftCacheOperations.Query] = Dictionary(
            uniqueKeysWithValues: cacheKeys.enumerated().map { ($0.element, .hit($0.offset)) }
        )
        let operations = TestSwiftCacheOperations(
            queries: queries,
            outputs: Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, cachedOutputs) }),
            replayStreams: .init(standardOutput: "cached-stdout", standardError: "cached-stderr")
        )
        operations.replaySideEffect = { compilation in
            for output in outputGroups[compilation] {
                try fs.write(output, contents: ByteString(encodingAsUTF8: output.basename))
            }
        }

        let accepted = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            semanticOutputJobKind: .compile,
            operations: operations,
            cacheKeys: cacheKeys,
            expectedOutputKindGroups: Array(repeating: plannedKinds, count: 10),
            plannedOutputs: outputs,
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(accepted.outcome == .unsafeTrustHit)
        #expect(accepted.cachedOutputCount == 50)
        #expect(outputs.allSatisfy(fs.exists))
        #expect(accepted.replayStreams?.count == 10)
        #expect(operations.replayedCompilations == Array(0..<10))

        for output in outputs where fs.exists(output) {
            try fs.remove(output)
        }
        operations.resetCalls()
        operations.replaySideEffect = { compilation in
            for output in outputGroups[compilation].dropLast() {
                try fs.write(output, contents: ByteString(encodingAsUTF8: output.basename))
            }
        }

        let missingDiagnostics = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            semanticOutputJobKind: .compile,
            operations: operations,
            cacheKeys: cacheKeys,
            expectedOutputKindGroups: Array(repeating: plannedKinds, count: 10),
            plannedOutputs: outputs,
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(missingDiagnostics.outcome == .replayError)
        #expect(missingDiagnostics.outcome.shouldExecuteFrontend)
        #expect(missingDiagnostics.replayStreams == nil)
        #expect(outputs.allSatisfy { !fs.exists($0) })
    }

    @Test
    func unsafeTrustSemanticModuleProfileStillRequiresEveryPlannedFile() throws {
        let fs = PseudoFS()
        try fs.createDirectory(Path("/build"), recursive: true)
        let outputs = [
            Path("/build/App.swiftmodule"),
            Path("/build/App.swiftdoc"),
            Path("/build/App.swiftsourceinfo"),
            Path("/build/App.emit-module.dia"),
            Path("/build/App.emit-module.d"),
            Path("/build/App.abi.json"),
        ]
        let cachedOutputs: [SwiftCacheCachedOutput] = [
            .init(kindName: "dependencies", isMaterialized: true),
            .init(kindName: "swiftmodule", isMaterialized: true),
            .init(kindName: "swiftdoc", isMaterialized: true),
            .init(kindName: "swiftsourceinfo", isMaterialized: true),
            .init(kindName: "abi-baseline-json", isMaterialized: true),
            .init(kindName: "cached-diagnostics", isMaterialized: true),
        ]
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: cachedOutputs],
            replayStreams: .init(standardOutput: "cached-stdout", standardError: "cached-stderr")
        )
        operations.replaySideEffect = { _ in
            for output in outputs {
                try fs.write(output, contents: ByteString(encodingAsUTF8: output.basename))
            }
        }

        let accepted = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            semanticOutputJobKind: .emitModule,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [[
                "swiftmodule", "swiftdoc", "swiftsourceinfo",
                "emit-module-diagnostics", "emit-module.d", "abi-baseline-json",
            ]],
            plannedOutputs: outputs,
            commandLine: ["swift-frontend", "-emit-module"],
            fs: fs
        )

        #expect(accepted.outcome == .unsafeTrustHit)
        #expect(accepted.cachedOutputCount == 6)
        #expect(outputs.allSatisfy(fs.exists))
        #expect(accepted.replayStreams == [
            .init(standardOutput: "cached-stdout", standardError: "cached-stderr")
        ])

        for output in outputs where fs.exists(output) {
            try fs.remove(output)
        }
        operations.resetCalls()
        operations.replaySideEffect = { _ in
            for (index, output) in outputs.enumerated() where index != 3 {
                try fs.write(output, contents: ByteString(encodingAsUTF8: output.basename))
            }
        }

        let missingDiagnostics = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            semanticOutputJobKind: .emitModule,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [[
                "swiftmodule", "swiftdoc", "swiftsourceinfo",
                "emit-module-diagnostics", "emit-module.d", "abi-baseline-json",
            ]],
            plannedOutputs: outputs,
            commandLine: ["swift-frontend", "-emit-module"],
            fs: fs
        )

        #expect(missingDiagnostics.outcome == .replayError)
        #expect(missingDiagnostics.outcome.shouldExecuteFrontend)
        #expect(missingDiagnostics.replayStreams == nil)
        #expect(outputs.allSatisfy { !fs.exists($0) })
    }

    @Test
    func unsafeTrustRejectsSingleMissingReplayOutput() throws {
        let fs = PseudoFS()
        let output = Path("/missing.o")
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]],
            replayStreams: .init(standardOutput: "must-not-leak", standardError: "must-not-leak")
        )

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(preparation.outcome == .replayError)
        #expect(preparation.outcome.shouldExecuteFrontend)
        #expect(preparation.scrubSucceeded == true)
        #expect(preparation.replayStreams == nil)
        #expect(operations.replayedCompilations == [1])
        #expect(!fs.exists(output))
    }

    @Test
    func unsafeTrustRejectsPartialMultiOutputReplayWithoutLeakingStreams() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let object = temporaryDirectory.path.join("main.o")
        let module = temporaryDirectory.path.join("Main.swiftmodule")
        let operations = TestSwiftCacheOperations(
            queries: ["object-key": .hit(1), "module-key": .hit(2)],
            outputs: [
                1: [.init(kindName: "object", isMaterialized: true)],
                2: [.init(kindName: "swiftmodule", isMaterialized: true)],
            ],
            replayStreamsByCompilation: [
                1: .init(standardOutput: "stdout-1", standardError: "stderr-1"),
                2: .init(standardOutput: "stdout-2", standardError: "stderr-2"),
            ]
        )
        operations.replaySideEffect = { compilation in
            if compilation == 1 {
                try localFS.write(object, contents: ByteString(encodingAsUTF8: "cached-object"))
            }
        }

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            operations: operations,
            cacheKeys: ["object-key", "module-key"],
            expectedOutputKindGroups: [["object"], ["swiftmodule"]],
            plannedOutputs: [object, module],
            commandLine: ["swift-frontend", "-c"],
            fs: localFS
        )

        #expect(preparation.outcome == .replayError)
        #expect(preparation.outcome.shouldExecuteFrontend)
        #expect(preparation.scrubSucceeded == true)
        #expect(preparation.replayStreams == nil)
        #expect(operations.replayedCompilations == [1, 2])
        #expect(!localFS.exists(object))
        #expect(!localFS.exists(module))
    }

    @Test
    func unsafeTrustReplayFailureDoesNotLeakPartialStreams() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let first = temporaryDirectory.path.join("first.o")
        let second = temporaryDirectory.path.join("second.swiftmodule")
        let operations = TestSwiftCacheOperations(
            queries: ["one": .hit(1), "two": .hit(2)],
            outputs: [
                1: [.init(kindName: "object", isMaterialized: true)],
                2: [.init(kindName: "swiftmodule", isMaterialized: true)],
            ],
            replayStreamsByCompilation: [
                1: .init(standardOutput: "stdout-1", standardError: "stderr-1"),
                2: .init(standardOutput: "stdout-2", standardError: "stderr-2"),
            ]
        )
        operations.failReplayForCompilation = 2
        operations.replaySideEffect = { compilation in
            let path = compilation == 1 ? first : second
            try localFS.write(path, contents: ByteString(encodingAsUTF8: "partial"))
        }

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            operations: operations,
            cacheKeys: ["one", "two"],
            expectedOutputKindGroups: [["object"], ["swiftmodule"]],
            plannedOutputs: [first, second],
            commandLine: ["swift-frontend", "-c"],
            fs: localFS
        )

        #expect(preparation.outcome == .replayError)
        #expect(preparation.outcome.shouldExecuteFrontend)
        #expect(preparation.scrubSucceeded == true)
        #expect(preparation.replayStreams == nil)
        #expect(operations.replayedCompilations == [1, 2])
        #expect(!localFS.exists(first))
        #expect(!localFS.exists(second))
    }
    #endif

    @Test
    func quarantinedVerifyDoesNotTouchCacheOrOutputs() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let output = temporaryDirectory.path.join("main.o")
        try fs.write(output, contents: ByteString(encodingAsUTF8: "fresh-frontend-owned"))
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            isQuarantined: { true }
        )

        #expect(preparation.outcome == .quarantined)
        #expect(preparation.outcome.shouldExecuteFrontend)
        #expect(preparation.lookupDurationNS == 0)
        #expect(preparation.replayDurationNS == nil)
        #expect(preparation.scrubDurationNS == nil)
        #expect(operations.queriedKeys.isEmpty)
        #expect(operations.replayedCompilations.isEmpty)
        #expect(try fs.read(output).asString == "fresh-frontend-owned")
        #expect(!SwiftDriverJobTaskAction.cachePreparationIsFatal(.quarantined, strictCASErrors: true))
    }

    @Test
    func quarantineRaisedDuringReplayStopsLaterCompilationsAndScrubsAllOutputs() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let first = temporaryDirectory.path.join("first.o")
        let second = temporaryDirectory.path.join("second.swiftmodule")
        let operations = TestSwiftCacheOperations(
            queries: ["one": .hit(1), "two": .hit(2)],
            outputs: [
                1: [.init(kindName: "object", isMaterialized: true)],
                2: [.init(kindName: "swiftmodule", isMaterialized: true)],
            ]
        )
        var quarantined = false
        operations.replaySideEffect = { compilation in
            guard compilation == 1 else { return }
            try fs.write(first, contents: ByteString(encodingAsUTF8: "cached-object"))
            try fs.write(second, contents: ByteString(encodingAsUTF8: "partial-module"))
            quarantined = true
        }

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["one", "two"],
            expectedOutputKindGroups: [["object"], ["swiftmodule"]],
            plannedOutputs: [first, second],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            isQuarantined: { quarantined }
        )

        #expect(preparation.outcome == .quarantined)
        #expect(preparation.outcome.shouldExecuteFrontend)
        #expect(preparation.scrubSucceeded == true)
        #expect(operations.queriedKeys == ["one", "two"])
        #expect(operations.replayedCompilations == [1])
        #expect(!fs.exists(first))
        #expect(!fs.exists(second))
    }

    @Test
    func privateTrustControlIsAlwaysStrippedFromFrontendEnvironment() {
        var environment = [
            SwiftAcceleratorCacheTrustAuthorization.environmentVariable: "v1",
            "UNRELATED": "preserved",
        ]

        SwiftAcceleratorCacheTrustAuthorization.removeControlVariable(from: &environment)

        #expect(environment[SwiftAcceleratorCacheTrustAuthorization.environmentVariable] == nil)
        #expect(environment["UNRELATED"] == "preserved")
    }

    #if SWIFT_BUILD_ACCELERATOR_TRUST_CANARY
    @Test
    func trustCanaryAuthorizationRequiresExactV1AndOnlyEnablesShadowPreparation() throws {
        #expect(SwiftAcceleratorCacheTrustAuthorization.parse(environment: [:]) == nil)
        for value in ["", "V1", " v1", "v1 ", "v1\n", "v1:", "v2"] {
            #expect(SwiftAcceleratorCacheTrustAuthorization.parse(environment: [
                SwiftAcceleratorCacheTrustAuthorization.environmentVariable: value
            ]) == nil)
        }
        let authorization = try #require(SwiftAcceleratorCacheTrustAuthorization.parse(environment: [
            SwiftAcceleratorCacheTrustAuthorization.environmentVariable: "v1"
        ]))

        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let output = temporaryDirectory.path.join("main.o")
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        operations.replaySideEffect = { _ in
            try fs.write(output, contents: ByteString(encodingAsUTF8: "cached-object"))
        }

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            trustAuthorization: authorization,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(preparation.outcome == .verificationReady)
        #expect(preparation.outcome.shouldExecuteFrontend)
        #expect(operations.queriedKeys == ["key"])
        #expect(operations.replayedCompilations == [1])
        #expect(!fs.exists(output), "authorized canary preparation must scrub its shadow outputs")

        operations.resetCalls()
        let sharedHeader = temporaryDirectory.path.join("App-Swift.h")
        let sharedHeaderPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .trust,
            trustAuthorization: authorization,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [output, sharedHeader],
            commandLine: ["swift-frontend", "-c", "-emit-objc-header-path", sharedHeader.str],
            fs: fs
        )
        #expect(sharedHeaderPreparation.outcome == .unsupportedOutput)
        #expect(sharedHeaderPreparation.outcome.shouldExecuteFrontend)
        #expect(operations.queriedKeys.isEmpty)
        #expect(operations.replayedCompilations.isEmpty)
    }
    #endif

    @Test
    func cacheFailuresFallBackNonStrictAndFailFastStrict() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let first = temporaryDirectory.path.join("first.o")
        let second = temporaryDirectory.path.join("second.swiftmodule")
        var quarantineCount = 0

        let queryFailure = TestSwiftCacheOperations(queries: ["key": .failure], outputs: [:])
        let queryPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: queryFailure,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [first],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            quarantineCache: { quarantineCount += 1 }
        )
        assertFallback(queryPreparation, expected: .queryError)
        #expect(quarantineCount == 0, "query failures must not quarantine replay")

        let createFailure = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        createFailure.failCreateReplay = true
        let createPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: createFailure,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [first],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            quarantineCache: { quarantineCount += 1 }
        )
        assertFallback(createPreparation, expected: .replayError)
        #expect(createPreparation.scrubSucceeded == true)
        #expect(quarantineCount == 1)

        let replayFailure = TestSwiftCacheOperations(
            queries: ["one": .hit(1), "two": .hit(2)],
            outputs: [
                1: [.init(kindName: "object", isMaterialized: true)],
                2: [.init(kindName: "swiftmodule", isMaterialized: true)],
            ]
        )
        replayFailure.failReplayForCompilation = 2
        replayFailure.replaySideEffect = { compilation in
            let path = compilation == 1 ? first : second
            try fs.write(path, contents: ByteString(encodingAsUTF8: "partial-\(compilation)"))
        }
        var replayQuarantineObservedBeforeScrub = false
        let replayPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: replayFailure,
            cacheKeys: ["one", "two"],
            expectedOutputKindGroups: [["object"], ["swiftmodule"]],
            plannedOutputs: [first, second],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            quarantineCache: {
                quarantineCount += 1
                replayQuarantineObservedBeforeScrub = fs.exists(first) && fs.exists(second)
            }
        )
        assertFallback(replayPreparation, expected: .replayError)
        #expect(replayPreparation.scrubSucceeded == true)
        #expect(quarantineCount == 2)
        #expect(replayQuarantineObservedBeforeScrub)
        #expect(!fs.exists(first))
        #expect(!fs.exists(second))

        let missingOutput = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [
                .init(kindName: "object", isMaterialized: true),
                .init(kindName: "swiftmodule", isMaterialized: true),
            ]]
        )
        missingOutput.replaySideEffect = { _ in
            try fs.write(first, contents: ByteString(encodingAsUTF8: "only-one-output"))
        }
        var manifestQuarantineObservedBeforeScrub = false
        let manifestPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: missingOutput,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object", "swiftmodule"]],
            plannedOutputs: [first, second],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            quarantineCache: {
                quarantineCount += 1
                manifestQuarantineObservedBeforeScrub = fs.exists(first)
            }
        )
        assertFallback(manifestPreparation, expected: .manifestError)
        #expect(manifestPreparation.scrubSucceeded == true)
        #expect(quarantineCount == 3)
        #expect(manifestQuarantineObservedBeforeScrub)
        #expect(!fs.exists(first))

        #expect(!SwiftDriverJobTaskAction.cachePreparationIsFatal(.miss, strictCASErrors: true))
        #expect(SwiftDriverJobTaskAction.cachePreparationIsFatal(.unavailable, strictCASErrors: true))
        #expect(!SwiftDriverJobTaskAction.cachePreparationIsFatal(.unavailable, strictCASErrors: false))
    }

    @Test
    func injectedCacheFaultsUseExistingOutcomeClassification() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let output = temporaryDirectory.path.join("main.o")

        func prepare(_ fault: SwiftAcceleratorCacheInjectedFault) -> (SwiftAcceleratorCachePreparation, TestSwiftCacheOperations) {
            let operations = TestSwiftCacheOperations(
                queries: ["key": .hit(1)],
                outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
            )
            operations.replaySideEffect = { _ in
                try fs.write(output, contents: ByteString(encodingAsUTF8: "cached-object"))
            }
            return (
                SwiftDriverJobTaskAction.prepareAcceleratorCache(
                    mode: .verify,
                    operations: operations,
                    cacheKeys: ["key"],
                    expectedOutputKindGroups: [["object"]],
                    plannedOutputs: [output],
                    commandLine: ["swift-frontend", "-c"],
                    fs: fs,
                    injectedFault: fault
                ),
                operations
            )
        }

        let (query, queryOperations) = prepare(.queryError)
        assertFallback(query, expected: .queryError)
        #expect(queryOperations.queriedKeys.isEmpty)

        let (replay, replayOperations) = prepare(.replayError)
        assertFallback(replay, expected: .replayError)
        #expect(replayOperations.queriedKeys == ["key"])
        #expect(replayOperations.replayedCompilations.isEmpty)
        #expect(replay.scrubSucceeded == true)
        #expect(!fs.exists(output))

        let (manifest, manifestOperations) = prepare(.manifestError)
        assertFallback(manifest, expected: .manifestError)
        #expect(manifestOperations.replayedCompilations == [1])
        #expect(manifest.scrubSucceeded == true)
        #expect(!fs.exists(output))
    }

    @Test
    func cancellationPrecedesEveryInjectedCacheFault() {
        let operations = TestSwiftCacheOperations(queries: ["key": .hit(1)], outputs: [:])
        for fault in [
            SwiftAcceleratorCacheInjectedFault.queryError,
            .replayError,
            .manifestError,
        ] {
            let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
                mode: .verify,
                operations: operations,
                cacheKeys: ["key"],
                expectedOutputKindGroups: [["object"]],
                plannedOutputs: [Path.temporaryDirectory.join("unused.o")],
                commandLine: ["swift-frontend", "-c"],
                fs: localFS,
                injectedFault: fault,
                isCancelled: { true }
            )
            #expect(preparation.outcome == .cancelled)
        }
        #expect(operations.queriedKeys.isEmpty)
    }

    @Test
    func injectedCacheFaultsAreIgnoredOutsideVerifyMode() {
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .observe,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [Path.temporaryDirectory.join("never-materialized.o")],
            commandLine: ["swift-frontend", "-c"],
            fs: localFS,
            injectedFault: .queryError
        )
        #expect(preparation.outcome == .wouldHit)
        #expect(operations.queriedKeys == ["key"])
        #expect(operations.replayedCompilations.isEmpty)
    }

    #if SWIFT_BUILD_ACCELERATOR_FAULT_INJECTION
    @Test
    func faultConfigurationIsClosedForMissingAndMalformedValues() {
        let selector = String(repeating: "a", count: 64)
        let valid = SwiftAcceleratorCacheFaultInjectionConfiguration(environment: [
            SwiftAcceleratorCacheFaultInjectionConfiguration.faultEnvironmentVariable: "v1:query_error:\(selector)",
            SwiftAcceleratorCacheFaultInjectionConfiguration.discoveryEnvironmentVariable: "1",
        ])
        #expect(valid.request?.fault == .queryError)
        #expect(valid.request?.selector == selector)
        #expect(valid.discoveryEnabled)

        let missing = SwiftAcceleratorCacheFaultInjectionConfiguration(environment: [:])
        #expect(missing.request == nil)
        #expect(!missing.discoveryEnabled)

        for malformed in [
            "query_error:\(selector)",
            "v2:query_error:\(selector)",
            "v1:unknown:\(selector)",
            "v1:query_error:\(String(repeating: "a", count: 63))",
            "v1:query_error:\(String(repeating: "A", count: 64))",
            "v1:query_error:\(String(repeating: "g", count: 64))",
            "v1:query_error:\(selector):extra",
        ] {
            let configuration = SwiftAcceleratorCacheFaultInjectionConfiguration(environment: [
                SwiftAcceleratorCacheFaultInjectionConfiguration.faultEnvironmentVariable: malformed,
            ])
            #expect(configuration.request == nil)
        }

        let malformedDiscovery = SwiftAcceleratorCacheFaultInjectionConfiguration(environment: [
            SwiftAcceleratorCacheFaultInjectionConfiguration.discoveryEnvironmentVariable: "YES",
        ])
        #expect(!malformedDiscovery.discoveryEnabled)

        var childEnvironment = [
            SwiftAcceleratorCacheFaultInjectionConfiguration.faultEnvironmentVariable: "v1:query_error:\(selector)",
            SwiftAcceleratorCacheFaultInjectionConfiguration.discoveryEnvironmentVariable: "1",
            "PRESERVED": "value",
        ]
        SwiftAcceleratorCacheFaultInjectionConfiguration.removeControlVariables(from: &childEnvironment)
        #expect(childEnvironment == ["PRESERVED": "value"])
    }

    @Test
    func faultSelectorIsDeterministicOpaqueAndPathFree() {
        let selector = SwiftDriverJobTaskAction.acceleratorFaultSelector(
            targetIdentity: "TARGET-GUID-/Users/private-project",
            arch: "arm64",
            variant: "normal",
            jobKey: .targetJob(7)
        )
        let repeated = SwiftDriverJobTaskAction.acceleratorFaultSelector(
            targetIdentity: "TARGET-GUID-/Users/private-project",
            arch: "arm64",
            variant: "normal",
            jobKey: .targetJob(7)
        )
        let differentJob = SwiftDriverJobTaskAction.acceleratorFaultSelector(
            targetIdentity: "TARGET-GUID-/Users/private-project",
            arch: "arm64",
            variant: "normal",
            jobKey: .targetJob(8)
        )
        let differentTarget = SwiftDriverJobTaskAction.acceleratorFaultSelector(
            targetIdentity: "OTHER-TARGET-GUID",
            arch: "arm64",
            variant: "normal",
            jobKey: .targetJob(7)
        )
        let explicitDependency = SwiftDriverJobTaskAction.acceleratorFaultSelector(
            targetIdentity: nil,
            arch: "arm64",
            variant: "normal",
            jobKey: .explicitDependencyJob(7)
        )
        let differentArchitecture = SwiftDriverJobTaskAction.acceleratorFaultSelector(
            targetIdentity: "TARGET-GUID-/Users/private-project",
            arch: "x86_64",
            variant: "normal",
            jobKey: .targetJob(7)
        )
        let differentVariant = SwiftDriverJobTaskAction.acceleratorFaultSelector(
            targetIdentity: "TARGET-GUID-/Users/private-project",
            arch: "arm64",
            variant: "profile",
            jobKey: .targetJob(7)
        )

        #expect(selector == repeated)
        #expect(selector != differentJob)
        #expect(selector != differentTarget)
        #expect(selector != explicitDependency)
        #expect(selector != differentArchitecture)
        #expect(selector != differentVariant)
        #expect(selector.utf8.count == 64)
        #expect(selector.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        })
        #expect(!selector.contains("Users"))
        #expect(!selector.contains("private-project"))
    }

    @Test
    func faultControllerRejectsWrongPolicyAndSelectorWithoutConsumingClaim() {
        let selector = String(repeating: "b", count: 64)
        let configuration = SwiftAcceleratorCacheFaultInjectionConfiguration(environment: [
            SwiftAcceleratorCacheFaultInjectionConfiguration.faultEnvironmentVariable: "v1:replay_error:\(selector)",
        ])
        let controller = SwiftAcceleratorCacheFaultInjectionController(configuration: configuration)

        #expect(!controller.claim(selector: selector, mode: .stock, eligibility: .eligible, checkpoint: .replayError))
        #expect(!controller.claim(selector: selector, mode: .observe, eligibility: .eligible, checkpoint: .replayError))
        #expect(!controller.claim(selector: selector, mode: .trust, eligibility: .eligible, checkpoint: .replayError))
        #expect(!controller.claim(selector: selector, mode: .verify, eligibility: .excluded(.unsupportedPlatform), checkpoint: .replayError))
        #expect(!controller.claim(selector: String(repeating: "c", count: 64), mode: .verify, eligibility: .eligible, checkpoint: .replayError))
        #expect(!controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .queryError))
        #expect(controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .replayError))
        #expect(!controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .replayError))
    }

    @Test
    func faultControllerClaimsExactlyOnceConcurrently() async {
        let selector = String(repeating: "d", count: 64)
        let configuration = SwiftAcceleratorCacheFaultInjectionConfiguration(environment: [
            SwiftAcceleratorCacheFaultInjectionConfiguration.faultEnvironmentVariable: "v1:manifest_error:\(selector)",
        ])
        let controller = SwiftAcceleratorCacheFaultInjectionController(configuration: configuration)
        let claimCount = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .manifestError) ? 1 : 0
                }
            }
            var total = 0
            for await value in group {
                total += value
            }
            return total
        }
        #expect(claimCount == 1)
    }

    @Test
    func missesAndCancellationDoNotConsumeLaterPhaseFaults() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        for fault in [SwiftAcceleratorCacheInjectedFault.replayError, .manifestError] {
            let expectedOutcome: SwiftAcceleratorCachePreparationOutcome = fault == .replayError ? .replayError : .manifestError
            let selector = fault == .replayError ? String(repeating: "e", count: 64) : String(repeating: "f", count: 64)
            let configuration = SwiftAcceleratorCacheFaultInjectionConfiguration(environment: [
                SwiftAcceleratorCacheFaultInjectionConfiguration.faultEnvironmentVariable: "v1:\(fault.rawValue):\(selector)",
            ])
            let controller = SwiftAcceleratorCacheFaultInjectionController(configuration: configuration)
            let claim: (SwiftAcceleratorCacheInjectedFault) -> Bool = { checkpoint in
                controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: checkpoint)
            }

            let miss = SwiftDriverJobTaskAction.prepareAcceleratorCache(
                mode: .verify,
                operations: TestSwiftCacheOperations(queries: ["key": .miss], outputs: [:]),
                cacheKeys: ["key"],
                expectedOutputKindGroups: [["object"]],
                plannedOutputs: [temporaryDirectory.path.join("miss-\(fault.rawValue).o")],
                commandLine: ["swift-frontend", "-c"],
                fs: localFS,
                claimInjectedFault: claim
            )
            #expect(miss.outcome == .miss)

            let cancelled = SwiftDriverJobTaskAction.prepareAcceleratorCache(
                mode: .verify,
                operations: TestSwiftCacheOperations(queries: ["key": .hit(1)], outputs: [:]),
                cacheKeys: ["key"],
                expectedOutputKindGroups: [["object"]],
                plannedOutputs: [temporaryDirectory.path.join("cancelled-\(fault.rawValue).o")],
                commandLine: ["swift-frontend", "-c"],
                fs: localFS,
                claimInjectedFault: claim,
                isCancelled: { true }
            )
            #expect(cancelled.outcome == .cancelled)

            let output = temporaryDirectory.path.join("later-\(fault.rawValue).o")
            let operations = TestSwiftCacheOperations(
                queries: ["key": .hit(1)],
                outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
            )
            operations.replaySideEffect = { _ in
                try localFS.write(output, contents: ByteString(encodingAsUTF8: "cached"))
            }
            let injected = SwiftDriverJobTaskAction.prepareAcceleratorCache(
                mode: .verify,
                operations: operations,
                cacheKeys: ["key"],
                expectedOutputKindGroups: [["object"]],
                plannedOutputs: [output],
                commandLine: ["swift-frontend", "-c"],
                fs: localFS,
                claimInjectedFault: claim
            )
            #expect(injected.outcome == expectedOutcome)

            let later = SwiftDriverJobTaskAction.prepareAcceleratorCache(
                mode: .verify,
                operations: operations,
                cacheKeys: ["key"],
                expectedOutputKindGroups: [["object"]],
                plannedOutputs: [output],
                commandLine: ["swift-frontend", "-c"],
                fs: localFS,
                claimInjectedFault: claim
            )
            #expect(later.outcome == .verificationReady)
        }
    }

    @Test(.requireHostOS(.macOS))
    func preScrubFailureDoesNotConsumeLaterPhaseFault() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        for fault in [SwiftAcceleratorCacheInjectedFault.replayError, .manifestError] {
            let expectedOutcome: SwiftAcceleratorCachePreparationOutcome = fault == .replayError ? .replayError : .manifestError
            let selector = fault == .replayError ? String(repeating: "1", count: 64) : String(repeating: "2", count: 64)
            let configuration = SwiftAcceleratorCacheFaultInjectionConfiguration(environment: [
                SwiftAcceleratorCacheFaultInjectionConfiguration.faultEnvironmentVariable: "v1:\(fault.rawValue):\(selector)",
            ])
            let controller = SwiftAcceleratorCacheFaultInjectionController(configuration: configuration)
            let claim: (SwiftAcceleratorCacheInjectedFault) -> Bool = { checkpoint in
                controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: checkpoint)
            }
            let lockedDirectory = temporaryDirectory.path.join("locked-\(fault.rawValue)")
            let blockedOutput = lockedDirectory.join("blocked.o")
            try localFS.createDirectory(lockedDirectory, recursive: true)
            try localFS.write(blockedOutput, contents: ByteString(encodingAsUTF8: "stale"))
            try localFS.setFilePermissions(lockedDirectory, permissions: 0o555)
            defer { try? localFS.setFilePermissions(lockedDirectory, permissions: 0o755) }
            let first = SwiftDriverJobTaskAction.prepareAcceleratorCache(
                mode: .verify,
                operations: TestSwiftCacheOperations(
                    queries: ["key": .hit(1)],
                    outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
                ),
                cacheKeys: ["key"],
                expectedOutputKindGroups: [["object"]],
                plannedOutputs: [blockedOutput],
                commandLine: ["swift-frontend", "-c"],
                fs: localFS,
                claimInjectedFault: claim
            )
            try localFS.setFilePermissions(lockedDirectory, permissions: 0o755)
            #expect(first.outcome == .scrubFailure)

            let laterOutput = temporaryDirectory.path.join("after-scrub-\(fault.rawValue).o")
            let laterOperations = TestSwiftCacheOperations(
                queries: ["key": .hit(1)],
                outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
            )
            laterOperations.replaySideEffect = { _ in
                try localFS.write(laterOutput, contents: ByteString(encodingAsUTF8: "cached"))
            }
            let later = SwiftDriverJobTaskAction.prepareAcceleratorCache(
                mode: .verify,
                operations: laterOperations,
                cacheKeys: ["key"],
                expectedOutputKindGroups: [["object"]],
                plannedOutputs: [laterOutput],
                commandLine: ["swift-frontend", "-c"],
                fs: localFS,
                claimInjectedFault: claim
            )
            #expect(later.outcome == expectedOutcome)
        }
    }

    @Test
    func cancellationConfigurationAndControllerFailClosed() {
        let selector = String(repeating: "7", count: 64)
        let readyDirectory = Path.temporaryDirectory.join("swift-cache-cancel-ready")
        let valid = SwiftAcceleratorCacheCancellationConfiguration(environment: [
            SwiftAcceleratorCacheCancellationConfiguration.environmentVariable: "v1:replay_stage:\(selector)",
            SwiftAcceleratorCacheCancellationConfiguration.readyDirectoryEnvironmentVariable: readyDirectory.str,
        ])
        #expect(valid.request?.checkpoint == .replayStage)
        #expect(valid.request?.selector == selector)
        #expect(valid.request?.readyDirectory == readyDirectory)

        let missingReadyDirectory = SwiftAcceleratorCacheCancellationConfiguration(environment: [
            SwiftAcceleratorCacheCancellationConfiguration.environmentVariable: "v1:replay_stage:\(selector)"
        ])
        #expect(missingReadyDirectory.request == nil)

        let relativeReadyDirectory = SwiftAcceleratorCacheCancellationConfiguration(environment: [
            SwiftAcceleratorCacheCancellationConfiguration.environmentVariable: "v1:replay_stage:\(selector)",
            SwiftAcceleratorCacheCancellationConfiguration.readyDirectoryEnvironmentVariable: "relative",
        ])
        #expect(relativeReadyDirectory.request == nil)

        for malformed in [
            "replay_stage:\(selector)",
            "v2:replay_stage:\(selector)",
            "v1:unknown:\(selector)",
            "v1:replay_stage:\(String(repeating: "7", count: 63))",
            "v1:replay_stage:\(String(repeating: "A", count: 64))",
            "v1:replay_stage:\(selector):extra",
        ] {
            let configuration = SwiftAcceleratorCacheCancellationConfiguration(environment: [
                SwiftAcceleratorCacheCancellationConfiguration.environmentVariable: malformed,
                SwiftAcceleratorCacheCancellationConfiguration.readyDirectoryEnvironmentVariable: readyDirectory.str,
            ])
            #expect(configuration.request == nil)
        }

        var childEnvironment = [
            SwiftAcceleratorCacheCancellationConfiguration.environmentVariable: "v1:replay_stage:\(selector)",
            SwiftAcceleratorCacheCancellationConfiguration.readyDirectoryEnvironmentVariable: readyDirectory.str,
            "PRESERVED": "value",
        ]
        SwiftAcceleratorCacheCancellationConfiguration.removeControlVariables(from: &childEnvironment)
        #expect(childEnvironment == ["PRESERVED": "value"])

        let controller = SwiftAcceleratorCacheCancellationController(configuration: valid)
        #expect(!controller.claim(selector: selector, mode: .observe, eligibility: .eligible, checkpoint: .replayStage))
        #expect(!controller.claim(selector: selector, mode: .verify, eligibility: .excluded(.unsupportedPlatform), checkpoint: .replayStage))
        #expect(!controller.claim(selector: String(repeating: "8", count: 64), mode: .verify, eligibility: .eligible, checkpoint: .replayStage))
        #expect(!controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .queryStage))
        #expect(controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .replayStage))
        #expect(!controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .replayStage))
    }

    @Test(.requireHostOS(.macOS))
    func cancellationReadyMarkerIsExclusiveDeterministicAndPrivate() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let readyDirectory = temporaryDirectory.path.join("ready")
        try localFS.createDirectory(readyDirectory)
        let selector = String(repeating: "8", count: 64)
        let markerPath = SwiftAcceleratorCacheCancellationReadyMarker.path(
            directory: readyDirectory,
            checkpoint: .postMaterialization,
            selector: selector
        )
        let expectedContents = ByteString(
            encodingAsUTF8: "schema\tswift-build-cache-cancel-ready-v1\ncheckpoint\tpost_materialization\nselector\t\(selector)\n"
        )

        let publishedPath = try SwiftAcceleratorCacheCancellationReadyMarker.publish(
            directory: readyDirectory,
            checkpoint: .postMaterialization,
            selector: selector,
            fs: localFS
        )
        #expect(publishedPath == markerPath)
        #expect(try localFS.read(markerPath) == expectedContents)
        #expect(try localFS.isFile(markerPath))
        #expect(!localFS.isSymlink(markerPath))
        #expect(try localFS.getFilePermissions(markerPath) == 0o600)

        #expect(throws: (any Error).self) {
            try SwiftAcceleratorCacheCancellationReadyMarker.publish(
                directory: readyDirectory,
                checkpoint: .postMaterialization,
                selector: selector,
                fs: localFS
            )
        }
        #expect(try localFS.read(markerPath) == expectedContents)
    }

    @Test(.requireHostOS(.macOS))
    func cancellationReadyMarkerRejectsSymlinksWithoutTouchingVictim() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let readyDirectory = temporaryDirectory.path.join("ready")
        let victim = temporaryDirectory.path.join("victim")
        try localFS.createDirectory(readyDirectory)
        try localFS.write(victim, contents: ByteString(encodingAsUTF8: "victim"))
        let selector = String(repeating: "9", count: 64)
        let markerPath = SwiftAcceleratorCacheCancellationReadyMarker.path(
            directory: readyDirectory,
            checkpoint: .queryStage,
            selector: selector
        )
        try localFS.symlink(markerPath, target: victim)

        #expect(throws: (any Error).self) {
            try SwiftAcceleratorCacheCancellationReadyMarker.publish(
                directory: readyDirectory,
                checkpoint: .queryStage,
                selector: selector,
                fs: localFS
            )
        }
        #expect(try localFS.read(victim) == ByteString(encodingAsUTF8: "victim"))

        let linkedDirectory = temporaryDirectory.path.join("linked-ready")
        try localFS.symlink(linkedDirectory, target: readyDirectory)
        #expect(throws: (any Error).self) {
            try SwiftAcceleratorCacheCancellationReadyMarker.publish(
                directory: linkedDirectory,
                checkpoint: .replayStage,
                selector: selector,
                fs: localFS
            )
        }
    }
    #endif

    @Test(.requireHostOS(.macOS))
    func scrubFailureIsAlwaysFatalAndBlocksFrontend() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let lockedDirectory = temporaryDirectory.path.join("locked")
        let output = lockedDirectory.join("cannot-remove.o")
        let laterOutput = temporaryDirectory.path.join("must-still-be-removed.swiftmodule")
        try fs.createDirectory(lockedDirectory, recursive: true)
        try fs.write(output, contents: ByteString(encodingAsUTF8: "cached-object"))
        try fs.write(laterOutput, contents: ByteString(encodingAsUTF8: "cached-module"))
        try fs.setFilePermissions(lockedDirectory, permissions: 0o555)
        defer { try? fs.setFilePermissions(lockedDirectory, permissions: 0o755) }
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [
                .init(kindName: "object", isMaterialized: true),
                .init(kindName: "swiftmodule", isMaterialized: true),
            ]]
        )

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object", "swiftmodule"]],
            plannedOutputs: [output, laterOutput],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )

        #expect(preparation.outcome == .scrubFailure)
        #expect(preparation.scrubSucceeded == false)
        #expect(!preparation.outcome.shouldExecuteFrontend)
        #expect(fs.exists(output))
        #expect(!fs.exists(laterOutput), "scrubbing must continue after an earlier removal failure")
        #expect(SwiftDriverJobTaskAction.cachePreparationIsFatal(.scrubFailure, strictCASErrors: false))
        #expect(SwiftDriverJobTaskAction.cachePreparationIsFatal(.scrubFailure, strictCASErrors: true))
    }

    @Test
    func sourceEditMissAndExactRevertHitWithoutSkippingCompilation() {
        let fs = localFS
        let operations = TestSwiftCacheOperations(
            queries: ["baseline-key": .hit(1), "edited-key": .miss],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )

        func observe(_ key: String) -> SwiftAcceleratorCachePreparation {
            SwiftDriverJobTaskAction.prepareAcceleratorCache(
                mode: .observe,
                operations: operations,
                cacheKeys: [key],
                expectedOutputKindGroups: [["object"]],
                plannedOutputs: [Path.temporaryDirectory.join("not-materialized-in-observe")],
                commandLine: ["swift-frontend", "-c"],
                fs: fs
            )
        }

        let baseline = observe("baseline-key")
        let edit = observe("edited-key")
        let revert = observe("baseline-key")
        #expect(baseline.outcome == .wouldHit)
        #expect(edit.outcome == .miss)
        #expect(revert.outcome == .wouldHit)
        #expect([baseline, edit, revert].allSatisfy { $0.outcome.shouldExecuteFrontend })
        #expect(operations.replayedCompilations.isEmpty)
    }

    @Test
    func onlyStockModeCanEnterUpstreamReplayPath() {
        #expect(SwiftDriverJobTaskAction.usesStockCacheReplayPath(mode: .stock))
        #expect(!SwiftDriverJobTaskAction.usesStockCacheReplayPath(mode: .observe))
        #expect(!SwiftDriverJobTaskAction.usesStockCacheReplayPath(mode: .verify))
        #expect(!SwiftDriverJobTaskAction.usesStockCacheReplayPath(mode: .trust))
    }

    @Test
    func cancellationIsObservedAtEveryInjectableCacheBoundary() throws {
        let operations = TestSwiftCacheOperations(
            queries: ["one": .hit(1), "two": .hit(2)],
            outputs: [
                1: [.init(kindName: "object", isMaterialized: true)],
                2: [.init(kindName: "swiftmodule", isMaterialized: true)],
            ]
        )

        #expect(throws: CancellationError.self) {
            try SwiftDriverJobTaskAction.probeCache(
                operations: operations,
                cacheKeys: ["one", "two"],
                expectedOutputKindGroups: [["object"], ["swiftmodule"]],
                isCancelled: { operations.queriedKeys.count == 1 }
            )
        }
        #expect(operations.queriedKeys == ["one"])

        operations.resetCalls()
        #expect(throws: CancellationError.self) {
            try SwiftDriverJobTaskAction.replayCache(
                operations: operations,
                compilations: [1],
                commandLine: ["swift-frontend", "-c"],
                isCancelled: { true }
            )
        }
        #expect(operations.replayCommandLine == nil, "cancellation must be checked before replay-instance creation")

        operations.resetCalls()
        #expect(throws: CancellationError.self) {
            try SwiftDriverJobTaskAction.replayCache(
                operations: operations,
                compilations: [1, 2],
                commandLine: ["swift-frontend", "-c"],
                isCancelled: { operations.replayedCompilations.count == 1 }
            )
        }
        #expect(operations.replayedCompilations == [1])

        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let first = temporaryDirectory.path.join("first.o")
        let second = temporaryDirectory.path.join("second.swiftmodule")
        try fs.write(first, contents: ByteString(encodingAsUTF8: "first"))
        try fs.write(second, contents: ByteString(encodingAsUTF8: "second"))

        var manifestChecks = 0
        #expect(throws: CancellationError.self) {
            try SwiftDriverJobTaskAction.makeOutputManifest([first, second], fs: fs) {
                manifestChecks += 1
                return manifestChecks == 2
            }
        }

        var scrubChecks = 0
        #expect(throws: CancellationError.self) {
            try SwiftDriverJobTaskAction.scrubOutputs([first, second], fs: fs) {
                scrubChecks += 1
                return scrubChecks == 2
            }
        }
        #expect(!fs.exists(first))
        #expect(!fs.exists(second), "cancellation must not leave later shadow outputs behind")

        #expect(!SwiftDriverJobTaskAction.shouldCancelBeforeFrontend(mode: .stock, isCancelled: true))
        #expect(!SwiftDriverJobTaskAction.shouldCancelBeforeFrontend(mode: .observe, isCancelled: false))
        #expect(SwiftDriverJobTaskAction.shouldCancelBeforeFrontend(mode: .observe, isCancelled: true))
        #expect(SwiftDriverJobTaskAction.shouldCancelBeforeFrontend(mode: .verify, isCancelled: true))
        #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
        #expect(SwiftDriverJobTaskAction.shouldCancelBeforeFrontend(mode: .trust, isCancelled: true))
        #else
        #expect(!SwiftDriverJobTaskAction.shouldCancelBeforeFrontend(mode: .trust, isCancelled: true))
        #endif
    }

    @Test
    func cooperativeCancellationPausesAtRealCacheStagesAndScrubsOutputs() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS

        let queryOperations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        var queryCheckpoints: [SwiftAcceleratorCacheCancellationCheckpoint] = []
        let query = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: queryOperations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [temporaryDirectory.path.join("query.o")],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            pauseAtCancellationCheckpoint: { checkpoint in
                queryCheckpoints.append(checkpoint)
                if checkpoint == .queryStage { throw CancellationError() }
            }
        )
        #expect(query.outcome == .cancelled)
        #expect(query.scrubSucceeded == nil)
        #expect(queryOperations.queriedKeys == ["key"])
        #expect(queryOperations.replayCommandLine == nil)
        #expect(queryCheckpoints == [.queryStage])

        let replayOutput = temporaryDirectory.path.join("replay.o")
        let replayOperations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        replayOperations.replaySideEffect = { _ in
            try fs.write(replayOutput, contents: ByteString(encodingAsUTF8: "must-not-run"))
        }
        let replay = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: replayOperations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [replayOutput],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            pauseAtCancellationCheckpoint: { checkpoint in
                if checkpoint == .replayStage { throw CancellationError() }
            }
        )
        #expect(replay.outcome == .cancelled)
        #expect(replay.scrubSucceeded == true)
        #expect(replayOperations.replayCommandLine == ["-c"])
        #expect(replayOperations.replayedCompilations.isEmpty)
        #expect(!fs.exists(replayOutput))

        let materializedOutput = temporaryDirectory.path.join("materialized.o")
        let materializedOperations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        materializedOperations.replaySideEffect = { _ in
            try fs.write(materializedOutput, contents: ByteString(encodingAsUTF8: "cached"))
        }
        let materialized = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: materializedOperations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [materializedOutput],
            commandLine: ["swift-frontend", "-c"],
            fs: fs,
            pauseAtCancellationCheckpoint: { checkpoint in
                if checkpoint == .postMaterialization { throw CancellationError() }
            }
        )
        #expect(materialized.outcome == .cancelled)
        #expect(materialized.scrubSucceeded == true)
        #expect(materialized.cachedOutputCount == 1)
        #expect(materializedOperations.replayedCompilations == [1])
        #expect(!fs.exists(materializedOutput), "post-materialization cancellation must scrub the replayed output")
    }

    @Test
    func cooperativeCancellationPauseIsIgnoredOutsideVerifyMode() {
        let operations = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .observe,
            operations: operations,
            cacheKeys: ["key"],
            expectedOutputKindGroups: [["object"]],
            plannedOutputs: [Path.temporaryDirectory.join("observe-never-replayed.o")],
            commandLine: ["swift-frontend", "-c"],
            fs: localFS,
            pauseAtCancellationCheckpoint: { _ in
                Issue.record("observe mode invoked the verify-only cancellation pause")
                throw CancellationError()
            }
        )
        #expect(preparation.outcome == .wouldHit)
        #expect(operations.replayedCompilations.isEmpty)
    }

    @Test
    func taskOutputDelegatePropagatesOnlyStructuredObservations() {
        let delegate = MockTaskOutputDelegate()
        let observations = [
            TaskCacheObservation(
                cacheKeys: ["raw-key-stays-task-local"],
                mode: .verify,
                eligibility: .eligible,
                outcome: .cacheError,
                scrubOutcome: .succeeded,
                fallbackReason: .replayError,
                finalDisposition: .executed
            ),
            TaskCacheObservation(
                mode: .trust,
                eligibility: .eligible,
                outcome: .unavailable,
                fallbackReason: .unauthorizedTrust,
                finalDisposition: .executed
            ),
            TaskCacheObservation(
                mode: .verify,
                eligibility: .eligible,
                outcome: .unavailable,
                fallbackReason: .buildQuarantined,
                finalDisposition: .executed
            ),
        ]

        for observation in observations {
            delegate.recordCacheObservation(observation)
        }

        #expect(delegate.cacheObservations == observations)
        #expect(delegate.cacheObservations.first?.fallbackReason == .replayError)
        #expect(delegate.cacheObservations.dropFirst().first?.fallbackReason == .unauthorizedTrust)
        #expect(delegate.cacheObservations.last?.fallbackReason == .buildQuarantined)
        #expect(delegate.cacheObservations.first?.finalDisposition == .executed)
    }

    private func assertFallback(
        _ preparation: SwiftAcceleratorCachePreparation,
        expected: SwiftAcceleratorCachePreparationOutcome,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(preparation.outcome == expected, sourceLocation: sourceLocation)
        #expect(preparation.outcome.shouldExecuteFrontend, sourceLocation: sourceLocation)
        #expect(preparation.shadowManifest == nil, sourceLocation: sourceLocation)
        #expect(preparation.replayStreams == nil, sourceLocation: sourceLocation)
        #expect(!SwiftDriverJobTaskAction.cachePreparationIsFatal(expected, strictCASErrors: false), sourceLocation: sourceLocation)
        #expect(SwiftDriverJobTaskAction.cachePreparationIsFatal(expected, strictCASErrors: true), sourceLocation: sourceLocation)
    }
}

private enum TestCacheError: Error {
    case injected
}

private final class TestSwiftCacheOperations: SwiftCacheOperations {
    enum Query {
        case hit(Int)
        case miss
        case failure
    }

    var queries: [String: Query]
    var outputs: [Int: [SwiftCacheCachedOutput]]
    let replayStreams: SwiftCacheReplayStreams
    let replayStreamsByCompilation: [Int: SwiftCacheReplayStreams]
    var failCreateReplay = false
    var failReplayForCompilation: Int?
    var querySideEffect: ((String) throws -> Void)?
    var replaySideEffect: ((Int) throws -> Void)?
    private(set) var queriedKeys: [String] = []
    private(set) var replayCommandLine: [String]?
    private(set) var replayedCompilations: [Int] = []

    init(
        queries: [String: Query],
        outputs: [Int: [SwiftCacheCachedOutput]],
        replayStreams: SwiftCacheReplayStreams = .init(standardOutput: "", standardError: ""),
        replayStreamsByCompilation: [Int: SwiftCacheReplayStreams] = [:]
    ) {
        self.queries = queries
        self.outputs = outputs
        self.replayStreams = replayStreams
        self.replayStreamsByCompilation = replayStreamsByCompilation
    }

    func resetCalls() {
        queriedKeys = []
        replayCommandLine = nil
        replayedCompilations = []
    }

    func queryLocalCacheKey(_ key: String) throws -> Int? {
        queriedKeys.append(key)
        try querySideEffect?(key)
        switch queries[key] ?? .miss {
        case .hit(let compilation):
            return compilation
        case .miss:
            return nil
        case .failure:
            throw TestCacheError.injected
        }
    }

    func cachedOutputs(for compilation: Int) throws -> [SwiftCacheCachedOutput] {
        outputs[compilation] ?? []
    }

    func createReplayInstance(commandLine: [String]) throws -> Int {
        replayCommandLine = commandLine
        if failCreateReplay {
            throw TestCacheError.injected
        }
        return 1
    }

    func replayCompilation(_ compilation: Int, using instance: Int) throws -> SwiftCacheReplayStreams {
        replayedCompilations.append(compilation)
        try replaySideEffect?(compilation)
        if compilation == failReplayForCompilation {
            throw TestCacheError.injected
        }
        return replayStreamsByCompilation[compilation] ?? replayStreams
    }
}
