// This source file is part of the Swift open source project.
// Licensed under Apache License v2.0 with Runtime Library Exception.

#if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
import Testing
@testable import SWBCore
import SWBUtil

/// SwiftBuildOptimizer C977: a warm record keeps the driver's skipped compile jobs, and replay
/// promotes the one that owns an edited file no planned job compiles.
@Suite
struct SwiftDriverSkippedCompileJobsTests {
    typealias Key = LibSwiftDriver.JobKey
    typealias Job = LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob
    private let cwd = Path("/tmp/skipped")
    private let sources = ["A", "B", "C"].map { Path("/tmp/skipped/\($0).swift") }

    private func job(_ rule: String, primaries: [String], arguments extra: [String] = [], inputs: [Path]? = nil,
                     outputs: [Path], kind: SwiftDriverJob.Kind = .target) throws -> SwiftDriverJob {
        var arguments = ["swift-frontend", "-frontend", "-c"]
        for primary in primaries { arguments += ["-primary-file", "/tmp/skipped/\(primary).swift"] }
        arguments += sources.map(\.str) + extra + ["-cache-compile-job", "-module-name", "M"]
        for output in outputs { arguments += ["-o", output.str] }
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(11) {
            serializer.serialize(kind)
            serializer.serialize(rule)
            serializer.serialize("M")
            serializer.serialize(inputs ?? sources)
            serializer.serialize(primaries.map { Path("/tmp/skipped/\($0).swift") })
            serializer.serialize(outputs)
            serializer.serialize(arguments.map { ByteString(encodingAsUTF8: $0) })
            serializer.serialize(ByteString(encodingAsUTF8: "signature-\(primaries)"))
            serializer.serialize("\(rule) \(primaries)")
            serializer.serialize(["key-\(primaries)"])
            serializer.serialize([["object"]])
        }
        return try MsgPackDeserializer.deserialize(serializer.byteString)
    }

    private func skipped(_ names: [String]) throws -> SwiftDriverSkippedCompileJobs {
        // Skipped jobs also read E.swift, which no planned job names.
        let jobs = try names.map { try job("Compile", primaries: [$0], inputs: sources + [Path("/tmp/skipped/E.swift")],
                                           outputs: [Path("/tmp/skipped/\($0).o")]) }
        let recorded = try #require(SwiftDriverSkippedCompileJobs(jobs: jobs))
        return try MsgPackDeserializer.deserialize(MsgPackSerializer.serialize(recorded))
    }

    /// One planned compile job for A, then an after-compilation job waiting for every compile job.
    private func plan(_ skippedNames: [String]) throws -> SwiftDriverPlanCacheSnapshot {
        let compile = Job(key: .targetJob(0), driverJob: try job("Compile", primaries: ["A"], outputs: [Path("/tmp/skipped/A.o")]),
                          dependencies: [], workingDirectory: cwd)
        let after = Job(key: .targetJob(1), driverJob: try job("Verify", primaries: [], inputs: [], outputs: [Path("/tmp/skipped/after")]),
                        dependencies: [.targetJob(0)], workingDirectory: cwd)
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(8) {
            serializer.serialize([compile, after])
            serializer.serialize([Path("/tmp/skipped/A.o"): Key.targetJob(0), Path("/tmp/skipped/after"): Key.targetJob(1)])
            serializer.serialize(Set<Key>())
            serializer.serialize(0..<0)
            serializer.serialize(0..<1)
            serializer.serialize(1..<2)
            serializer.serialize(1..<1)
            serializer.serialize(cwd)
        }
        let planned: LibSwiftDriver.PlannedBuild.CacheSnapshot = try MsgPackDeserializer.deserialize(serializer.byteString)
        return SwiftDriverPlanCacheSnapshot(plannedBuild: planned, explicitModuleJobs: [], swiftmodulesNeedingRegistration: [],
                                            planningDependencies: [], transitiveDependencyModuleNames: [],
                                            skippedCompileJobs: try skipped(skippedNames))
    }

    @Test
    func recordedJobsRebuildExactly() throws {
        let jobs = [
            try job("Compile", primaries: ["B"], outputs: [Path("/tmp/skipped/B.o")]),
            try job("Compile", primaries: ["C"], outputs: [Path("/tmp/skipped/C.o")]),
            try job("Compile", primaries: ["A"], arguments: ["-extra"], inputs: [sources[0]], outputs: [Path("/tmp/skipped/A.o")]),
        ]
        let recorded: SwiftDriverSkippedCompileJobs = try MsgPackDeserializer.deserialize(
            MsgPackSerializer.serialize(try #require(SwiftDriverSkippedCompileJobs(jobs: jobs))))
        #expect(recorded.count == 3)
        for (index, original) in jobs.enumerated() {
            let rebuilt = recorded.job(at: index)
            #expect(rebuilt.commandLine == original.commandLine)
            #expect(rebuilt.inputs == original.inputs)
            #expect(rebuilt.outputs == original.outputs)
            #expect(rebuilt.displayInputs == original.displayInputs)
            #expect(rebuilt.descriptionForLifecycle == original.descriptionForLifecycle)
            #expect(rebuilt.cacheKeys.isEmpty)
        }
        #expect(recorded.primaryFiles(of: 1) == ["/tmp/skipped/C.swift"])
        #expect(recorded.primaryFiles(of: 2) == ["/tmp/skipped/A.swift"])
        #expect(recorded.distinctInputLists == [sources, [sources[0]]])
        #expect(SwiftDriverSkippedCompileJobs(jobs: [try job("Verify", primaries: ["B"], outputs: [])]) == nil)
    }

    @Test
    func promotesTheSkippedOwnerAndShiftsLaterJobs() throws {
        let result = try plan(["B", "C"]).invalidatingCompilationCacheKeys(
            forSources: [sources[0], sources[1]], canonicalize: { $0 }, isRegularFile: { _ in true })
        #expect(result.ownership == [1, 1])
        #expect(result.invalidatedJobCount == 2)
        #expect(result.promotedSkipped == 1)
        let planned = result.snapshot.plannedBuild
        #expect(planned.plannedTargetJobs.map(\.key) == [.targetJob(0), .targetJob(1), .targetJob(2)])
        #expect(planned.compilationIndices == 0..<2)
        #expect(planned.afterCompilationIndices == 2..<3)
        #expect(planned.verificationIndices == 2..<2)
        let promoted = planned.plannedTargetJobs[1].driverJob
        #expect(promoted.displayInputs == [sources[1]])
        #expect(!promoted.commandLine.contains(ByteString(encodingAsUTF8: "-cache-compile-job")))
        #expect(planned.plannedTargetJobs[2].dependencies == [.targetJob(0), .targetJob(1)])
        #expect(planned.producerMap[Path("/tmp/skipped/B.o")] == .targetJob(1))
        #expect(planned.producerMap[Path("/tmp/skipped/after")] == .targetJob(2))
        try result.snapshot.validateForUnchangedNativePlanning(workingDirectory: cwd)
    }

    @Test
    func leavesOwnedEditsAndUnrecordedFilesAlone() throws {
        let owned = try plan(["B"]).invalidatingCompilationCacheKeys(
            forSources: [sources[0]], canonicalize: { $0 }, isRegularFile: { _ in true })
        #expect(owned.promotedSkipped == 0)
        #expect(owned.snapshot.plannedBuild.plannedTargetJobs.count == 2)
        let unrecorded = try plan(["B"]).invalidatingCompilationCacheKeys(
            forSources: [sources[0], sources[2]], canonicalize: { $0 }, isRegularFile: { _ in true })
        #expect(unrecorded.ownership == [1, 0])
        #expect(unrecorded.promotedSkipped == 0)
        // Without the canonicalizing grammar nothing is promoted.
        let strict = try plan(["B"]).invalidatingCompilationCacheKeys(forSources: [sources[1]])
        #expect(strict.ownership == [0])
    }

    @Test
    func skippedInputsAreNeverAbsent() throws {
        let snapshot = try plan(["B"])
        #expect(!snapshot.provesSourceAbsent(for: sources[1], canonicalize: { $0 }, isRegularFile: { _ in true }))
        var skippedReasons: [String] = []
        #expect(!snapshot.provesSourceAbsent(for: Path("/tmp/skipped/E.swift"), canonicalize: { $0 }, isRegularFile: { _ in true },
                                             rejection: { skippedReasons.append($0) }))
        #expect(skippedReasons == ["Compile: skipped-source-is-input"])
        #expect(SwiftDriverPlanCacheSnapshot(plannedBuild: snapshot.plannedBuild, explicitModuleJobs: [],
                                             swiftmodulesNeedingRegistration: [], planningDependencies: [],
                                             transitiveDependencyModuleNames: [])
            .provesSourceAbsent(for: Path("/tmp/skipped/E.swift"), canonicalize: { $0 }, isRegularFile: { _ in true }))
        let elsewhere = Path("/tmp/elsewhere/D.swift")
        var reasons: [String] = []
        _ = snapshot.provesSourceAbsent(for: elsewhere, canonicalize: { $0 }, isRegularFile: { _ in true },
                                        rejection: { reasons.append($0) })
        #expect(!reasons.contains { $0.contains("skipped") })
    }
}
#endif
