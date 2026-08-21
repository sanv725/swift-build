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
        #expect(baseline.entries.map(\.fileKind) == [.regularFile, .regularFile])
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
        let valid = SwiftAcceleratorCacheCancellationConfiguration(environment: [
            SwiftAcceleratorCacheCancellationConfiguration.environmentVariable: "v1:replay_stage:\(selector)"
        ])
        #expect(valid.request?.checkpoint == .replayStage)
        #expect(valid.request?.selector == selector)

        for malformed in [
            "replay_stage:\(selector)",
            "v2:replay_stage:\(selector)",
            "v1:unknown:\(selector)",
            "v1:replay_stage:\(String(repeating: "7", count: 63))",
            "v1:replay_stage:\(String(repeating: "A", count: 64))",
            "v1:replay_stage:\(selector):extra",
        ] {
            let configuration = SwiftAcceleratorCacheCancellationConfiguration(environment: [
                SwiftAcceleratorCacheCancellationConfiguration.environmentVariable: malformed
            ])
            #expect(configuration.request == nil)
        }

        var childEnvironment = [
            SwiftAcceleratorCacheCancellationConfiguration.environmentVariable: "v1:replay_stage:\(selector)",
            "PRESERVED": "value",
        ]
        SwiftAcceleratorCacheCancellationConfiguration.removeControlVariable(from: &childEnvironment)
        #expect(childEnvironment == ["PRESERVED": "value"])

        let controller = SwiftAcceleratorCacheCancellationController(configuration: valid)
        #expect(!controller.claim(selector: selector, mode: .observe, eligibility: .eligible, checkpoint: .replayStage))
        #expect(!controller.claim(selector: selector, mode: .verify, eligibility: .excluded(.unsupportedPlatform), checkpoint: .replayStage))
        #expect(!controller.claim(selector: String(repeating: "8", count: 64), mode: .verify, eligibility: .eligible, checkpoint: .replayStage))
        #expect(!controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .queryStage))
        #expect(controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .replayStage))
        #expect(!controller.claim(selector: selector, mode: .verify, eligibility: .eligible, checkpoint: .replayStage))
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
    func cancellationIsObservedAtEveryInjectableCacheBoundary() throws {
        let operations = TestSwiftCacheOperations(
            queries: ["one": .hit(1), "two": .hit(2)],
            outputs: [
                1: [.init(kindName: "object", isMaterialized: true)],
                2: [.init(kindName: "module", isMaterialized: true)],
            ]
        )

        #expect(throws: CancellationError.self) {
            try SwiftDriverJobTaskAction.probeCache(
                operations: operations,
                cacheKeys: ["one", "two"],
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
        #expect(!SwiftDriverJobTaskAction.shouldCancelBeforeFrontend(mode: .trust, isCancelled: true))
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
