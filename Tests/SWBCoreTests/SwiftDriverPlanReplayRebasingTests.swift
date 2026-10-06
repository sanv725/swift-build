// This source file is part of the Swift open source project.
// Licensed under Apache License v2.0 with Runtime Library Exception.

#if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
import Testing
@testable import SWBCore
import SWBUtil

@Suite
struct SwiftDriverPlanReplayRebasingTests {
    typealias Key = LibSwiftDriver.JobKey
    typealias Job = LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob
    private let cwd = Path("/tmp/replay")

    private func driver(_ id: Int) throws -> SwiftDriverJob {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(11) {
            serializer.serialize(SwiftDriverJob.Kind.explicitModule(uniqueID: id))
            serializer.serialize("CompileModule")
            serializer.serialize("Module\(id)")
            serializer.serialize([Path]())
            serializer.serialize([Path]())
            serializer.serialize([Path("/tmp/replay/Module\(id).swiftmodule")])
            serializer.serialize([ByteString(encodingAsUTF8: "swift-frontend")])
            serializer.serialize(ByteString(encodingAsUTF8: "signature\(id)"))
            serializer.serialize("Module \(id)")
            serializer.serialize([String]())
            serializer.serialize([[String]]())
        }
        return try MsgPackDeserializer.deserialize(serializer.byteString)
    }

    private func fixture(
        keys: [Key] = [.explicitDependencyJob(3), .explicitDependencyJob(9)],
        ids: [Int] = [30, 90],
        covered: Set<Key>? = nil,
        extraProducer: Key? = nil,
        extraDependency: Key? = nil,
        explicitCWD: Path? = nil
    ) throws -> SwiftDriverPlanCacheSnapshot {
        let first = Job(key: keys[0], driverJob: try driver(ids[0]), dependencies: [], workingDirectory: explicitCWD ?? cwd)
        let second = Job(key: keys[1], driverJob: try driver(ids[1]), dependencies: [keys[0]], workingDirectory: cwd)
        let target = Job(key: .targetJob(0), driverJob: try driver(100), dependencies: [keys[1]] + (extraDependency.map { [$0] } ?? []), workingDirectory: cwd)
        var producers = [Path("/tmp/replay/Module30.swiftmodule"): keys[0], Path("/tmp/replay/Module90.swiftmodule"): keys[1]]
        if let extraProducer { producers[Path("/tmp/replay/extra")] = extraProducer }
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(8) {
            serializer.serialize([target])
            serializer.serialize(producers)
            serializer.serialize(covered ?? Set(keys))
            serializer.serialize(0..<0)
            serializer.serialize(0..<1)
            serializer.serialize(1..<1)
            serializer.serialize(1..<1)
            serializer.serialize(cwd)
        }
        let plan: LibSwiftDriver.PlannedBuild.CacheSnapshot = try MsgPackDeserializer.deserialize(serializer.byteString)
        return SwiftDriverPlanCacheSnapshot(plannedBuild: plan, explicitModuleJobs: [first, second], swiftmodulesNeedingRegistration: ["debug"], planningDependencies: ["input"], transitiveDependencyModuleNames: ["Module30", "Module90"])
    }

    @Test
    func sparseIDsRebaseEveryExecutionReference() throws {
        let original = try fixture()
        let replay = try original.rebasedForReplay()
        #expect(replay.explicitModuleJobs.map(\.key) == [.explicitDependencyJob(0), .explicitDependencyJob(1)])
        #expect(replay.explicitModuleJobs[1].dependencies == [.explicitDependencyJob(0)])
        #expect(replay.plannedBuild.plannedTargetJobs[0].dependencies == [.explicitDependencyJob(1)])
        #expect(replay.plannedBuild.plannedTargetJobs[0].key == .targetJob(0))
        #expect(replay.plannedBuild.producerMap[Path("/tmp/replay/Module90.swiftmodule")] == .explicitDependencyJob(1))
        #expect(replay.plannedBuild.explicitModuleBuildJobKeys == [.explicitDependencyJob(0), .explicitDependencyJob(1)])
        #expect(replay.plannedBuild.plannedTargetJobs[0].signature == original.plannedBuild.plannedTargetJobs[0].signature)
        #expect(replay.explicitModuleJobs[1].signature == original.explicitModuleJobs[1].signature)
        #expect(replay.plannedBuild.compilationIndices == original.plannedBuild.compilationIndices)
        #expect(replay.explicitModuleJobs[1].driverJob.commandLine == original.explicitModuleJobs[1].driverJob.commandLine)
        #expect(replay.explicitModuleJobs[1].driverJob.outputs == original.explicitModuleJobs[1].driverJob.outputs)
        #expect(replay.swiftmodulesNeedingRegistration == original.swiftmodulesNeedingRegistration)
        #expect(replay.planningDependencies == original.planningDependencies)
        #expect(replay.transitiveDependencyModuleNames == original.transitiveDependencyModuleNames)
        #expect(original.explicitModuleJobs.map(\.key) == [.explicitDependencyJob(3), .explicitDependencyJob(9)])
    }

    @Test
    func denseRebasingIsIdempotent() throws {
        let original = try fixture(keys: [.explicitDependencyJob(0), .explicitDependencyJob(1)])
        let first = try original.rebasedForReplay()
        let second = try first.rebasedForReplay()
        #expect(MsgPackSerializer.serialize(first) == MsgPackSerializer.serialize(second))
    }

    @Test
    func rejectsMissingCoverageDuplicateIDsUnmappedEdgesAndForeignJobs() throws {
        let negatives = [
            try fixture(covered: [.explicitDependencyJob(3)]),
            try fixture(keys: [.explicitDependencyJob(3), .explicitDependencyJob(3)]),
            try fixture(keys: [.explicitDependencyJob(9), .explicitDependencyJob(3)]),
            try fixture(keys: [.targetJob(3), .explicitDependencyJob(9)]),
            try fixture(ids: [30, 30]),
            try fixture(extraProducer: .explicitDependencyJob(99)),
            try fixture(extraDependency: .explicitDependencyJob(99)),
            try fixture(explicitCWD: Path("/tmp/foreign")),
        ]
        for snapshot in negatives {
            #expect(throws: (any Error).self) { try snapshot.rebasedForReplay() }
        }
    }
}
#endif
