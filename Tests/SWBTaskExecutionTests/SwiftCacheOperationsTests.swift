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
                    .init(kindName: "module", isMaterialized: true),
                    .init(kindName: "dependencies", isMaterialized: true),
                ],
            ]
        )

        switch try SwiftDriverJobTaskAction.probeCache(operations: operations, cacheKeys: ["one", "two"]) {
        case .hit(let compilations, let outputCount):
            #expect(compilations == [1, 2])
            #expect(outputCount == 3)
        case .miss:
            Issue.record("complete multi-key cache entry was reported as a miss")
        }
        #expect(operations.queriedKeys == ["one", "two"])

        operations.resetCalls()
        operations.queries["two"] = .miss
        switch try SwiftDriverJobTaskAction.probeCache(operations: operations, cacheKeys: ["one", "two"]) {
        case .hit:
            Issue.record("missing second key was reported as a hit")
        case .miss(let reason):
            #expect(reason == .missingKey)
        }
        #expect(operations.queriedKeys == ["one", "two"])

        operations.resetCalls()
        operations.queries["two"] = .hit(2)
        operations.outputs[2] = [.init(kindName: "module", isMaterialized: false)]
        switch try SwiftDriverJobTaskAction.probeCache(operations: operations, cacheKeys: ["one", "two"]) {
        case .hit:
            Issue.record("nonmaterialized output was reported as a hit")
        case .miss(let reason):
            #expect(reason == .nonMaterializedOutput)
        }

        operations.resetCalls()
        switch try SwiftDriverJobTaskAction.probeCache(operations: operations, cacheKeys: []) {
        case .hit:
            Issue.record("empty key list was reported as a hit")
        case .miss(let reason):
            #expect(reason == .missingKey)
        }
        #expect(operations.queriedKeys.isEmpty)
    }

    @Test
    func probeAndReplayErrorsPropagateToTheFailOpenDecisionBoundary() throws {
        let operations = TestSwiftCacheOperations(
            queries: ["one": .failure, "two": .hit(2)],
            outputs: [2: [.init(kindName: "object", isMaterialized: true)]]
        )
        #expect(throws: TestCacheError.self) {
            try SwiftDriverJobTaskAction.probeCache(operations: operations, cacheKeys: ["one", "two"])
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
    func shadowReplayIsOrderedAndDoesNotExposeCachedStreams() throws {
        let secretOutput = "cached diagnostic and stdout must stay shadowed"
        let operations = TestSwiftCacheOperations(
            queries: [:],
            outputs: [:],
            replayStreams: .init(standardOutput: secretOutput, standardError: secretOutput)
        )

        try SwiftDriverJobTaskAction.replayCache(
            operations: operations,
            compilations: [3, 1, 2],
            commandLine: ["swift-frontend", "-frontend", "-c"]
        )

        #expect(operations.replayCommandLine == ["-frontend", "-c"])
        #expect(operations.replayedCompilations == [3, 1, 2])
        // The helper deliberately returns Void, so cached stdout/stderr cannot
        // become the authoritative compiler's output by accident.
    }

    @Test
    func outputManifestDetectsContentCountAndMissingOutput() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let first = temporaryDirectory.path.join("first.o")
        let second = temporaryDirectory.path.join("module.swiftmodule")
        try fs.write(first, contents: ByteString(encodingAsUTF8: "first"))
        try fs.write(second, contents: ByteString(encodingAsUTF8: "second"))

        let baseline = try SwiftDriverJobTaskAction.makeOutputManifest([first, second], fs: fs)
        #expect(baseline.entries.map(\.ordinal) == [0, 1])
        #expect(baseline.entries.map(\.byteCount) == [5, 6])
        #expect(baseline.totalBytes == 11)
        #expect(baseline.mismatchCount(comparedTo: baseline) == 0)

        try fs.write(second, contents: ByteString(encodingAsUTF8: "changed"))
        let contentMismatch = try SwiftDriverJobTaskAction.makeOutputManifest([first, second], fs: fs)
        #expect(baseline.mismatchCount(comparedTo: contentMismatch) == 1)

        let countMismatch = try SwiftDriverJobTaskAction.makeOutputManifest([first], fs: fs)
        #expect(baseline.mismatchCount(comparedTo: countMismatch) == 1)

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
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        #expect(externallyRequestedTrust == .observe)
        #expect(trustPreparation.outcome == .wouldHit)
        #expect(trustPreparation.outcome.shouldExecuteFrontend)
        #expect(trustPreparation.shadowManifest == nil)
        #expect(operations.replayedCompilations.isEmpty)

        operations.resetCalls()
        let verified = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
            plannedOutputs: [output],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        #expect(verified.outcome == .verificationReady)
        #expect(verified.outcome.shouldExecuteFrontend)
        #expect(verified.shadowManifest?.entries.count == 1)
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
    func cacheFailuresFallBackNonStrictAndFailFastStrict() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let fs = localFS
        let first = temporaryDirectory.path.join("first.o")
        let second = temporaryDirectory.path.join("second.swiftmodule")

        let queryFailure = TestSwiftCacheOperations(queries: ["key": .failure], outputs: [:])
        let queryPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: queryFailure,
            cacheKeys: ["key"],
            plannedOutputs: [first],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        assertFallback(queryPreparation, expected: .queryError)

        let createFailure = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        createFailure.failCreateReplay = true
        let createPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: createFailure,
            cacheKeys: ["key"],
            plannedOutputs: [first],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        assertFallback(createPreparation, expected: .replayError)
        #expect(createPreparation.scrubSucceeded == true)

        let replayFailure = TestSwiftCacheOperations(
            queries: ["one": .hit(1), "two": .hit(2)],
            outputs: [
                1: [.init(kindName: "object", isMaterialized: true)],
                2: [.init(kindName: "module", isMaterialized: true)],
            ]
        )
        replayFailure.failReplayForCompilation = 2
        replayFailure.replaySideEffect = { compilation in
            let path = compilation == 1 ? first : second
            try fs.write(path, contents: ByteString(encodingAsUTF8: "partial-\(compilation)"))
        }
        let replayPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: replayFailure,
            cacheKeys: ["one", "two"],
            plannedOutputs: [first, second],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        assertFallback(replayPreparation, expected: .replayError)
        #expect(replayPreparation.scrubSucceeded == true)
        #expect(!fs.exists(first))
        #expect(!fs.exists(second))

        let missingOutput = TestSwiftCacheOperations(
            queries: ["key": .hit(1)],
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )
        missingOutput.replaySideEffect = { _ in
            try fs.write(first, contents: ByteString(encodingAsUTF8: "only-one-output"))
        }
        let manifestPreparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: missingOutput,
            cacheKeys: ["key"],
            plannedOutputs: [first, second],
            commandLine: ["swift-frontend", "-c"],
            fs: fs
        )
        assertFallback(manifestPreparation, expected: .manifestError)
        #expect(manifestPreparation.scrubSucceeded == true)
        #expect(!fs.exists(first))

        #expect(!SwiftDriverJobTaskAction.cachePreparationIsFatal(.miss, strictCASErrors: true))
        #expect(SwiftDriverJobTaskAction.cachePreparationIsFatal(.unavailable, strictCASErrors: true))
        #expect(!SwiftDriverJobTaskAction.cachePreparationIsFatal(.unavailable, strictCASErrors: false))
    }

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
            outputs: [1: [.init(kindName: "object", isMaterialized: true)]]
        )

        let preparation = SwiftDriverJobTaskAction.prepareAcceleratorCache(
            mode: .verify,
            operations: operations,
            cacheKeys: ["key"],
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
    func taskOutputDelegatePropagatesOnlyStructuredObservations() {
        let delegate = MockTaskOutputDelegate()
        let observation = TaskCacheObservation(
            cacheKeys: ["raw-key-stays-task-local"],
            mode: .verify,
            eligibility: .eligible,
            outcome: .cacheError,
            scrubOutcome: .succeeded,
            fallbackReason: .replayError,
            finalDisposition: .executed
        )

        delegate.recordCacheObservation(observation)

        #expect(delegate.cacheObservations == [observation])
        #expect(delegate.cacheObservations.first?.fallbackReason == .replayError)
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
    var failCreateReplay = false
    var failReplayForCompilation: Int?
    var replaySideEffect: ((Int) throws -> Void)?
    private(set) var queriedKeys: [String] = []
    private(set) var replayCommandLine: [String]?
    private(set) var replayedCompilations: [Int] = []

    init(
        queries: [String: Query],
        outputs: [Int: [SwiftCacheCachedOutput]],
        replayStreams: SwiftCacheReplayStreams = .init(standardOutput: "", standardError: "")
    ) {
        self.queries = queries
        self.outputs = outputs
        self.replayStreams = replayStreams
    }

    func resetCalls() {
        queriedKeys = []
        replayCommandLine = nil
        replayedCompilations = []
    }

    func queryLocalCacheKey(_ key: String) throws -> Int? {
        queriedKeys.append(key)
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
        return replayStreams
    }
}
