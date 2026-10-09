//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

import SwiftDriver
import SwiftOptions
package import TSCBasic

public import SWBUtil

public protocol SwiftGlobalExplicitDependencyGraph : AnyObject {
    /// Register a collection of driver jobs in the graph, de-duplicating them in the process
    /// - Parameters:
    ///   - jobs: A collection of explicit-dependency build jobs from a given Swift Driver invocation
    ///   - producerMap: A map of build products to their producer job
    /// - Returns: A set of `JobKey`s corresponding to the added jobs, either de-duplicated to an existing key already in a graph, or newly-added
    func addExplicitDependencyBuildJobs(_ jobs: [SwiftDriverJob], workingDirectory: Path, producerMap: inout [Path: LibSwiftDriver.JobKey]) throws -> Set<LibSwiftDriver.JobKey>

    /// Query all explicit dependency build jobs corresponding to a collection of keys
    /// - Parameters:
    ///    - keys: A collection of keys to query their corresponding `PlannedSwiftDriverJob` values
    /// - Returns: An array of `PlannedSwiftDriverJob` values corresponding to the query keys
    func getExplicitDependencyBuildJobs(for keys: [LibSwiftDriver.JobKey]) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob]

    /// Query a specific explicit dependency build jobs corresponding to a provided key
    /// - Parameters:
    ///    - key: A single `JobKey` for which to query the existence of a corresponding `PlannedSwiftDriverJob`
    /// - Returns: An optional `PlannedSwiftDriverJob` corresponding to the key. `nil` if no such job has been registered with the graph
    func plannedExplicitDependencyBuildJob(for key: LibSwiftDriver.JobKey) -> LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob?

    /// Query all job dependencies of a given explicit dependency-build `PlannedSwiftDriverJob`.
    /// Only other explicit dependency build jobs can be dependencies of such a job, so they can all be resolved by this query.
    /// - Parameters:
    ///    - job: `PlannedSwiftDriverJob` whose dependencies are queried
    /// - Returns: A collection of `PlannedSwiftDriverJob`s that produce values depended on by the `job` parameter Job.
    func explicitDependencies(for job: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob]
}

#if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
/// Complete execution-facing result of one integrated Swift Driver planning
/// phase. The wrapper's exact action key owns compatibility and invalidation.
public struct SwiftDriverPlanCacheSnapshot: Serializable {
    // Version 2 plans retain debugger search paths in compilation cache keys.
    // Version 3 plans record the driver's skipped compile jobs (SwiftBuildOptimizer C977).
    public static let schemaVersion = 3

    public let schemaVersion: Int
    public let plannedBuild: LibSwiftDriver.PlannedBuild.CacheSnapshot
    public let explicitModuleJobs: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob]
    public let swiftmodulesNeedingRegistration: [String]
    public let planningDependencies: [String]
    public let transitiveDependencyModuleNames: [String]
    public let skippedCompileJobs: SwiftDriverSkippedCompileJobs

    public init(
        plannedBuild: LibSwiftDriver.PlannedBuild.CacheSnapshot,
        explicitModuleJobs: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob],
        swiftmodulesNeedingRegistration: [String],
        planningDependencies: [String],
        transitiveDependencyModuleNames: [String],
        skippedCompileJobs: SwiftDriverSkippedCompileJobs = .empty
    ) {
        self.schemaVersion = Self.schemaVersion
        self.plannedBuild = plannedBuild
        self.explicitModuleJobs = explicitModuleJobs
        self.swiftmodulesNeedingRegistration = swiftmodulesNeedingRegistration
        self.planningDependencies = planningDependencies
        self.transitiveDependencyModuleNames = transitiveDependencyModuleNames
        self.skippedCompileJobs = skippedCompileJobs
    }

    /// A recorded target selects sparse IDs from the build-wide tracker. Replay
    /// uses a fresh tracker, so remap the entire execution graph with a bijection.
    func rebasedForReplay() throws -> Self {
        typealias Key = LibSwiftDriver.JobKey
        let keys = explicitModuleJobs.map(\.key)
        guard keys == keys.sorted(), Set(keys).count == keys.count,
              Set(keys) == plannedBuild.explicitModuleBuildJobKeys else {
            throw StubError.error("Cached explicit dependency coverage is inconsistent.")
        }
        var mapping: [Key: Key] = [:]
        var uniqueIDs: Set<Int> = []
        for (index, job) in explicitModuleJobs.enumerated() {
            guard case .explicitDependencyJob(let oldIndex) = job.key, oldIndex >= 0,
                  case .explicitModule(let uniqueID) = job.driverJob.kind,
                  uniqueIDs.insert(uniqueID).inserted,
                  job.workingDirectory == plannedBuild.workingDirectory else {
                throw StubError.error("Cached explicit dependency identity is inconsistent.")
            }
            mapping[job.key] = .explicitDependencyJob(index)
        }
        func remap(_ key: Key) throws -> Key {
            guard case .explicitDependencyJob = key else { return key }
            guard let value = mapping[key] else {
                throw StubError.error("Cached plan contains an unmapped explicit dependency.")
            }
            return value
        }
        return try Self(
            plannedBuild: plannedBuild.remappingExplicitKeys(mapping),
            explicitModuleJobs: explicitModuleJobs.map { job in
                LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob(
                    key: try remap(job.key), driverJob: job.driverJob,
                    dependencies: try job.dependencies.map(remap),
                    workingDirectory: job.workingDirectory, signature: job.signature
                )
            },
            swiftmodulesNeedingRegistration: swiftmodulesNeedingRegistration,
            planningDependencies: planningDependencies,
            transitiveDependencyModuleNames: transitiveDependencyModuleNames,
            skippedCompileJobs: skippedCompileJobs
        )
    }

    /// Side-effect-free, conservative structure validation for the opt-in
    /// absence telemetry. Does not install a cached plan or publish graph state.
    public func validateForUnchangedNativePlanning(workingDirectory: Path) throws {
        let snapshot = try rebasedForReplay()
        let plan = snapshot.plannedBuild
        let targetCount = plan.plannedTargetJobs.count
        guard plan.workingDirectory == workingDirectory,
              targetCount <= 4096, snapshot.explicitModuleJobs.count <= 4096 else {
            throw StubError.error("Unchanged planning snapshot directory or bound is invalid.")
        }
        let phases = [plan.compilationRequirementsIndices, plan.compilationIndices,
                      plan.verificationIndices, plan.afterCompilationIndices]
        var end = 0
        for phase in phases {
            guard phase.lowerBound == end, phase.upperBound >= end,
                  phase.upperBound <= targetCount else {
                throw StubError.error("Unchanged planning snapshot phase coverage is invalid.")
            }
            end = phase.upperBound
        }
        guard end == targetCount else {
            throw StubError.error("Unchanged planning snapshot target coverage is incomplete.")
        }
        for (index, job) in plan.plannedTargetJobs.enumerated() {
            guard job.key == .targetJob(index) else {
                throw StubError.error("Unchanged planning snapshot target keys are invalid.")
            }
        }
        let jobs = plan.plannedTargetJobs + snapshot.explicitModuleJobs
        let keys = Set(jobs.map(\.key))
        guard keys.count == jobs.count else {
            throw StubError.error("Unchanged planning snapshot has duplicate jobs.")
        }
        var producers: [Path: LibSwiftDriver.JobKey] = [:]
        var incoming: [LibSwiftDriver.JobKey: Int] = [:]
        var consumers: [LibSwiftDriver.JobKey: [LibSwiftDriver.JobKey]] = [:]
        for job in jobs {
            guard job.workingDirectory == workingDirectory,
                  Set(job.dependencies).count == job.dependencies.count,
                  job.dependencies.allSatisfy({ keys.contains($0) && $0 != job.key }) else {
                throw StubError.error("Unchanged planning snapshot dependencies are invalid.")
            }
            incoming[job.key] = job.dependencies.count
            for dependency in job.dependencies { consumers[dependency, default: []].append(job.key) }
            for output in job.driverJob.outputs {
                guard output.isAbsolute, producers.updateValue(job.key, forKey: output) == nil else {
                    throw StubError.error("Unchanged planning snapshot output ownership is ambiguous.")
                }
            }
        }
        guard producers == plan.producerMap else {
            throw StubError.error("Unchanged planning snapshot producer map did not reproduce.")
        }
        var queue = jobs.filter { $0.dependencies.isEmpty }.map(\.key)
        var cursor = 0
        while cursor < queue.count {
            let key = queue[cursor]; cursor += 1
            for consumer in consumers[key] ?? [] {
                incoming[consumer]! -= 1
                if incoming[consumer] == 0 { queue.append(consumer) }
            }
        }
        guard queue.count == jobs.count else {
            throw StubError.error("Unchanged planning snapshot dependency graph is cyclic.")
        }
    }

    public func provesSourceAbsent(for source: Path, canonicalize: (String) -> String?) -> Bool {
        provesSourceAbsent(for: source, canonicalize: canonicalize, isRegularFile: { _ in false })
    }

    public func provesSourceAbsent(for source: Path, canonicalize: (String) -> String?,
                                  isRegularFile: (String) -> Bool,
                                  readFileList: ((String) -> [String]?)? = nil,
                                  readResponseFile: ((String) -> String?)? = nil,
                                  rejection: ((String) -> Void)? = nil,
                                  referenced: ((String) -> Void)? = nil) -> Bool {
        let jobs = plannedBuild.plannedTargetJobs + explicitModuleJobs
        guard !jobs.isEmpty else { rejection?("no-jobs"); return false }
        // A skipped compile job reads every module source (C977): its inputs are not absent.
        if skippedCompileJobs.count > 0 {
            guard source.isAbsolute, let canonicalSource = canonicalize(source.str) else {
                rejection?("Compile: source"); return false
            }
            for inputs in skippedCompileJobs.distinctInputLists {
                for input in inputs {
                    guard input.isAbsolute, let path = canonicalize(input.str) else {
                        rejection?("Compile: skipped-input-unresolved"); return false
                    }
                    guard path != canonicalSource else { rejection?("Compile: skipped-source-is-input"); return false }
                }
            }
        }
        return jobs.allSatisfy { job in
            var arguments = job.driverJob.commandLine.map { $0.asString }
            if arguments.contains(where: { $0.hasPrefix("@") }) {
                // Expand one trailing driver response file only when it reproduces the planned
                // command-line signature exactly; otherwise the proof stays unproven.
                guard let readResponseFile, arguments.count == 3, arguments[2].hasPrefix("@/"),
                      !arguments[0].hasPrefix("@"), !arguments[1].hasPrefix("@"),
                      let text = readResponseFile(String(arguments[2].dropFirst())) else {
                    rejection?(job.driverJob.ruleInfoType + ": response-file-unreadable"); return false
                }
                let expanded = Array(arguments[0..<2]) + SwiftDriverPrimaryInputOwnership.parseResponseFile(text)
                let context = InsecureHashContext()
                for argument in expanded { context.add(string: argument) }
                guard context.signature == job.driverJob.commandLineSignature else {
                    rejection?(job.driverJob.ruleInfoType + ": response-file-signature"); return false
                }
                arguments = expanded
            }
            return SwiftDriverPrimaryInputOwnership.provesAbsence(
                source: source.str, arguments: arguments,
                inputs: job.driverJob.inputs.map { $0.str },
                isCompile: job.driverJob.ruleInfoType == "Compile", canonicalize: canonicalize,
                isRegularFile: isRegularFile, readFileList: readFileList,
                rejection: rejection.map { report in { report(job.driverJob.ruleInfoType + ": " + $0) } },
                referenced: referenced)
        }
    }

    /// Source-independent half of `provesSourcesAbsent`, for a persistent absence certificate:
    /// every path any source would be compared with, or nil when the proof fails regardless of
    /// the source. A source is then proven absent exactly when it canonicalizes to a path
    /// outside the returned set.
    public func absenceReferences(canonicalize: (String) -> String?,
                                  isRegularFile: (String) -> Bool,
                                  readFileList: ((String) -> [String]?)? = nil,
                                  readResponseFile: ((String) -> String?)? = nil,
                                  rejection: ((String) -> Void)? = nil) -> Set<String>? {
        // A path no plan names. Were one to match, the proof would only fail (conservative).
        let sentinel = "/.swift-build-absence-sentinel-" + UUID().uuidString
        var references = Set<String>()
        let proven = provesSourceAbsent(for: Path(sentinel), canonicalize: { value in
            if value == sentinel { return sentinel }
            let result = canonicalize(value)
            if let result { references.insert(result) }
            return result
        }, isRegularFile: isRegularFile, readFileList: readFileList,
           readResponseFile: readResponseFile, rejection: rejection,
           referenced: { references.insert($0) })
        return proven ? references : nil
    }

    /// Multi-file replay v1: sources must each be checked with `provesSourcesAbsent` when unowned.
    public func provesSourcesAbsent(_ sources: [Path], canonicalize: (String) -> String?,
                                   isRegularFile: (String) -> Bool,
                                   readFileList: ((String) -> [String]?)? = nil,
                                   readResponseFile: ((String) -> String?)? = nil,
                                   rejection: ((String) -> Void)? = nil) -> Bool {
        !sources.isEmpty && sources.allSatisfy { source in
            provesSourceAbsent(for: source, canonicalize: canonicalize, isRegularFile: isRegularFile,
                               readFileList: readFileList, readResponseFile: readResponseFile, rejection: rejection)
        }
    }

    public func invalidatingCompilationCacheKeys(
        forSources sources: [Path], canonicalize: ((String) -> String?)? = nil,
        isRegularFile: ((String) -> Bool)? = nil,
        readFileList: ((String) -> [String]?)? = nil
    ) -> (snapshot: Self, invalidatedJobCount: Int, ownership: [Int], droppedPrimaries: Int, promotedSkipped: Int) {
        let result = plannedBuild.invalidatingCompilationCacheKeys(forSources: sources,
            canonicalize: canonicalize, isRegularFile: isRegularFile, readFileList: readFileList,
            skipped: skippedCompileJobs)
        return (
            Self(
                plannedBuild: result.snapshot,
                explicitModuleJobs: explicitModuleJobs,
                swiftmodulesNeedingRegistration: swiftmodulesNeedingRegistration,
                planningDependencies: planningDependencies,
                transitiveDependencyModuleNames: transitiveDependencyModuleNames,
                skippedCompileJobs: skippedCompileJobs
            ),
            result.invalidatedJobCount, result.ownership, result.droppedPrimaries, result.promotedSkipped
        )
    }

    public func invalidatingCompilationCacheKeys(
        for source: Path, canonicalize: ((String) -> String?)? = nil,
        isRegularFile: ((String) -> Bool)? = nil,
        readFileList: ((String) -> [String]?)? = nil
    ) -> (snapshot: Self, invalidatedJobCount: Int) {
        let result = plannedBuild.invalidatingCompilationCacheKeys(for: source,
            canonicalize: canonicalize, isRegularFile: isRegularFile, readFileList: readFileList)
        return (
            Self(
                plannedBuild: result.snapshot,
                explicitModuleJobs: explicitModuleJobs,
                swiftmodulesNeedingRegistration: swiftmodulesNeedingRegistration,
                planningDependencies: planningDependencies,
                transitiveDependencyModuleNames: transitiveDependencyModuleNames
            ),
            result.invalidatedJobCount
        )
    }

    public func serialize<T>(to serializer: T) where T: Serializer {
        serializer.serializeAggregate(7) {
            serializer.serialize(schemaVersion)
            serializer.serialize(plannedBuild)
            serializer.serialize(explicitModuleJobs)
            serializer.serialize(swiftmodulesNeedingRegistration)
            serializer.serialize(planningDependencies)
            serializer.serialize(transitiveDependencyModuleNames)
            serializer.serialize(skippedCompileJobs)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        try schemaVersion = deserializer.deserialize()
        guard schemaVersion == Self.schemaVersion else {
            throw StubError.error("Unsupported Swift Driver plan cache schema \(schemaVersion).")
        }
        try plannedBuild = deserializer.deserialize()
        try explicitModuleJobs = deserializer.deserialize()
        try swiftmodulesNeedingRegistration = deserializer.deserialize()
        try planningDependencies = deserializer.deserialize()
        try transitiveDependencyModuleNames = deserializer.deserialize()
        try skippedCompileJobs = deserializer.deserialize()
    }
}
#endif

/// Keeps track of all of the explicit module dependency build jobs as depended on by individual target builds
private struct GlobalExplicitDependencyTracker {
    /// Maps a SwiftDriverJob's UniqueID to its index in this store
    private var uniqueIndexMap: [Int: Int] = [:]

    /// The collection of *all* explicit module dependency build jobs found so far
    fileprivate private(set) var plannedExplicitDependencyJobs: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] = []

    /// Stage both tracker and caller map: a collision must not publish half a
    /// batch or corrupt the caller's Apple planning state.
    mutating func addExplicitDependencyBuildJobs(_ jobs: [SwiftDriverJob], workingDirectory: Path,
                                                 producerMap: inout [Path: LibSwiftDriver.JobKey]) throws -> Set<LibSwiftDriver.JobKey> {
        var staged = self
        var producers = producerMap
        let keys = try staged.stageExplicitJobs(jobs, workingDirectory: workingDirectory, producerMap: &producers)
        self = staged
        producerMap = producers
        return keys
    }

    private mutating func stageExplicitJobs(_ jobs: [SwiftDriverJob], workingDirectory: Path,
                                            producerMap: inout [Path: LibSwiftDriver.JobKey]) throws -> Set<LibSwiftDriver.JobKey> {
        typealias Planned = LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob
        typealias Key = LibSwiftDriver.JobKey
        let initialCount = plannedExplicitDependencyJobs.count
        var selected: [(SwiftDriverJob, Int)] = []
        for job in jobs {
            guard case let .explicitModule(uid) = job.kind else {
                throw StubError.error("Unexpected target job in explicit module builds.")
            }
            let index: Int
            if let existing = uniqueIndexMap[uid] {
                let candidate = plannedExplicitDependencyJobs[existing]
                guard candidate.driverJob.hasSameExplicitAction(as: job), candidate.workingDirectory == workingDirectory else {
                    throw StubError.error("Explicit module UID collision with incompatible action. " + candidate.driverJob.explicitActionDifferences(from: job, workingDirectory: candidate.workingDirectory, other: workingDirectory))
                }
                index = existing
            } else if let existing = plannedExplicitDependencyJobs.firstIndex(where: {
                $0.workingDirectory == workingDirectory && $0.driverJob.hasSameExplicitAction(as: job)
            }) {
                index = existing
            } else {
                index = plannedExplicitDependencyJobs.count
                plannedExplicitDependencyJobs.append(Planned(key: .explicitDependencyJob(index), driverJob: job, dependencies: [], workingDirectory: workingDirectory))
            }
            uniqueIndexMap[uid] = index
            let key = Key.explicitDependencyJob(index)
            for output in job.outputs {
                if let previous = producerMap[output], previous != key {
                    throw StubError.error("Explicit module output has an incompatible producer: \(output).")
                }
                producerMap[output] = key
            }
            selected.append((job, index))
        }
        var established: Set<Int> = []
        for (job, index) in selected {
            let dependencies = Set(job.inputs.compactMap { producerMap[$0] }).sorted()
            guard dependencies.allSatisfy({ if case .explicitDependencyJob = $0 { return true }; return false }),
                  !dependencies.contains(.explicitDependencyJob(index)) else {
                throw StubError.error("Explicit module dependencies include a target or self edge.")
            }
            if index < initialCount || established.contains(index) {
                // A later target only sees producers in its own planning map, so it can rebuild a
                // subset of the dependencies of a job first planned in an earlier batch. Reframe
                // (C959) showed this for CFNetwork, Darwin, Dispatch, Security and os_workgroup,
                // all with only-new 0. The established superset already orders every edge this
                // target can see. Any new dependency the established job lacks is still rejected.
                // Approved by the owner on 2026-10-07.
                guard Set(dependencies).isSubset(of: Set(plannedExplicitDependencyJobs[index].dependencies)) else {
                    let previous = Set(plannedExplicitDependencyJobs[index].dependencies), current = Set(dependencies)
                    throw StubError.error("Explicit module action has incompatible dependencies. module \(job.moduleName); first \(previous.count) new \(current.count); only-first \(previous.subtracting(current).count); only-new \(current.subtracting(previous).count); first-was-in-earlier-batch \(index < initialCount)")
                }
            } else {
                plannedExplicitDependencyJobs[index] = Planned(key: .explicitDependencyJob(index), driverJob: job, dependencies: dependencies, workingDirectory: workingDirectory)
                established.insert(index)
            }
        }
        var visiting: Set<Int> = []
        var visited: Set<Int> = []
        func visit(_ index: Int) throws {
            guard plannedExplicitDependencyJobs.indices.contains(index) else { throw StubError.error("Unknown explicit dependency edge.") }
            if visited.contains(index) { return }
            guard visiting.insert(index).inserted else { throw StubError.error("Explicit dependency cycle.") }
            for dependency in plannedExplicitDependencyJobs[index].dependencies {
                guard case .explicitDependencyJob(let next) = dependency else { throw StubError.error("Explicit dependency is a target edge.") }
                try visit(next)
            }
            visiting.remove(index)
            visited.insert(index)
        }
        for index in plannedExplicitDependencyJobs.indices { try visit(index) }
        return Set(selected.map { .explicitDependencyJob($0.1) })
    }

    #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
    /// Reuse a live signature for shared jobs; newly imported jobs retain the
    /// recorded signature rather than recomputing a process-local hash.
    mutating func importingCachedJobs(_ jobs: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob],
                                     workingDirectory: Path) throws -> [LibSwiftDriver.JobKey: LibSwiftDriver.JobKey] {
        let initialCount = plannedExplicitDependencyJobs.count
        var producers: [Path: LibSwiftDriver.JobKey] = [:]
        let keys = try addExplicitDependencyBuildJobs(jobs.map(\.driverJob), workingDirectory: workingDirectory, producerMap: &producers)
        var mapping: [LibSwiftDriver.JobKey: LibSwiftDriver.JobKey] = [:]
        for job in jobs {
            guard let index = plannedExplicitDependencyJobs.firstIndex(where: {
                $0.workingDirectory == job.workingDirectory && $0.driverJob.hasSameExplicitAction(as: job.driverJob)
            }), keys.contains(.explicitDependencyJob(index)) else {
                throw StubError.error("Cached explicit module action did not reproduce.")
            }
            mapping[job.key] = .explicitDependencyJob(index)
        }
        for job in jobs {
            guard let key = mapping[job.key], case .explicitDependencyJob(let index) = key else {
                throw StubError.error("Cached explicit module key is unmapped.")
            }
            let dependencies = try job.dependencies.map { dependency -> LibSwiftDriver.JobKey in
                guard let mapped = mapping[dependency] else { throw StubError.error("Cached explicit dependency is unmapped.") }
                return mapped
            }
            guard Set(dependencies).sorted() == plannedExplicitDependencyJobs[index].dependencies else {
                throw StubError.error("Cached explicit module dependencies did not reproduce.")
            }
            if index >= initialCount {
                plannedExplicitDependencyJobs[index] = .init(key: key, driverJob: job.driverJob, dependencies: Set(dependencies).sorted(),
                                                            workingDirectory: job.workingDirectory, signature: job.signature)
            }
        }
        return mapping
    }
    #endif

    func getExplicitDependencyBuildJobs(for keys: [LibSwiftDriver.JobKey]) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] {
        var jobs: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] = []
        for key in keys {
            guard case .explicitDependencyJob(let index) = key else {
                assertionFailure("Unexpectedly found a regular job in 'plannedExplicitDependencyJobs'")
                continue
            }
            guard plannedExplicitDependencyJobs.indices.contains(index) else {
                assertionFailure("Unexpectedly found an out of bounds job index into 'plannedExplicitDependencyJobs'")
                continue
            }
            let job = plannedExplicitDependencyJobs[index]
            assert(job.key == key)
            jobs.append(job)
        }
        return jobs
    }

    public func plannedExplicitDependencyBuildJob(for key: LibSwiftDriver.JobKey) -> LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob? {
        let jobs = getExplicitDependencyBuildJobs(for: [key])
        return jobs.first
    }

    func explicitDependencies(for job: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] {
        return job.dependencies.compactMap(plannedExplicitDependencyBuildJob(for:))
    }
}

/// Build wide graph used to plan a module build
public final class SwiftModuleDependencyGraph: SwiftGlobalExplicitDependencyGraph {
    /// The key to oracle registry for swift dependency scanning
    struct OracleRegistryKey: Hashable {
        let compilerLocation: LibSwiftDriver.CompilerLocation
        let casOpts: CASOptions?
    }
    let oracleRegistry: Registry<OracleRegistryKey, InterModuleDependencyOracle> = .init()

    #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
    /// A replay-only scanner must never share opaque scanner or CAS handles with
    /// the Apple scanner used for dependency planning. Retaining its oracle in a
    /// separate registry keeps the custom dylib and every wrapper it creates
    /// alive for the complete build lifetime.
    struct AcceleratorReplayOracleRegistryKey: Hashable {
        let compilerLocation: LibSwiftDriver.CompilerLocation
        let libSwiftScanPath: Path
        let casOpts: CASOptions
    }
    let acceleratorReplayOracleRegistry: Registry<AcceleratorReplayOracleRegistryKey, InterModuleDependencyOracle> = .init()
    #endif

    private let registryQueue = SWBQueue(label: "SwiftModuleDependencyGraph", autoreleaseFrequency: .workItem)
    private var registry: [String: LibSwiftDriver] = [:]
    private var globalExplicitDependencyTracker = GlobalExplicitDependencyTracker()
    private enum OutputOwner: Equatable { case target(UUID), explicit(LibSwiftDriver.JobKey) }
    private var outputOwners: [Path: OutputOwner] = [:]
    private var issuedTargetTokens: Set<UUID> = []
    private var revision: UInt64 = 0

    // Tokens/reservations live until this graph is destroyed, including after
    // cleanup. A late callback cannot acquire a removed target's outputs.
    internal func makeTargetToken() -> UUID {
        registryQueue.blocking_sync {
            let token = UUID()
            precondition(issuedTargetTokens.insert(token).inserted)
            return token
        }
    }

    private func reserving(_ outputs: [Path], for owner: OutputOwner,
                          in reservations: [Path: OutputOwner]) throws -> [Path: OutputOwner] {
        var result = reservations
        for output in outputs {
            if let previous = result[output], previous != owner {
                throw StubError.error("Swift Driver output reservation collision: \(output).")
            }
            result[output] = owner
        }
        return result
    }

    /// Reserves an explicit module job's outputs. Two explicit jobs for the same module, rule, working
    /// directory and inputs may name one output when only their target triples differ: IceCubesApp's
    /// packages plan `simd` for iOS 15.0 and 16.0, and Clang's module hash omits the version
    /// (SwiftBuildOptimizer C969). Stock swift-build runs both jobs; the first reservation is kept here.
    /// Any other collision is rejected with the differing action fields.
    private func reservingExplicit(_ job: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob,
                                   jobs: (LibSwiftDriver.JobKey) -> LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob?,
                                   in reservations: [Path: OutputOwner]) throws -> [Path: OutputOwner] {
        var result = reservations
        for output in job.driverJob.outputs {
            if let existing = result[output], existing != .explicit(job.key) {
                guard case .explicit(let previousKey) = existing, let previous = jobs(previousKey) else {
                    throw StubError.error("Swift Driver output reservation collision: \(output).")
                }
                guard previous.driverJob.moduleName == job.driverJob.moduleName,
                      previous.driverJob.ruleInfoType == job.driverJob.ruleInfoType,
                      previous.workingDirectory == job.workingDirectory,
                      Set(previous.driverJob.inputs) == Set(job.driverJob.inputs) else {
                    throw StubError.error("Swift Driver output reservation collision: \(output). " +
                        previous.driverJob.explicitActionDifferences(from: job.driverJob,
                            workingDirectory: previous.workingDirectory, other: job.workingDirectory))
                }
                continue
            }
            result[output] = .explicit(job.key)
        }
        return result
    }

    internal func reserveTargetOutputs(_ outputs: [Path], token: UUID) throws {
        try registryQueue.blocking_sync {
            guard issuedTargetTokens.contains(token) else { throw StubError.error("Unknown target reservation token.") }
            let reservations = try reserving(outputs, for: .target(token), in: outputOwners)
            if reservations != outputOwners { outputOwners = reservations; revision += 1 }
        }
    }

    public init() {}

    public func waitForCompletion() async {
        await registryQueue.sync { }
    }

    /// Plans a build and stores it for a given unique identifier.
    /// - Parameters:
    ///   - key: ID that will be used to store the planned build uniquely. Needs to be equal for the `queryPlannedBuild` call.
    ///   - compilerPath: The absolute path to the compiler binary (to base other tools on)
    ///   - target: The target that gets build
    ///   - args: The whole command line invocation for the module
    ///   - workingDirectory: The directory which should be used as a working directory for the invocation to resolve relative paths
    ///   - tempDirPath: The directory which should be used to output modules
    ///   - environment: The environment to use for executing jobs
    ///   - eagerCompilationEnabled: Flag to indicate state of eager compilation in Swift
    ///   - casOptions: The CAS configuration option and `nil` if no CAS is needed
    /// - Returns: A tuple containing a boolean indicating success and an array of diagnostics
    public func planBuild(key: String, compilerLocation: LibSwiftDriver.CompilerLocation, target: ConfiguredTarget, args: [String], workingDirectory: Path, tempDirPath: Path, explicitModulesTempDirPath: Path, environment: [String: String], eagerCompilationEnabled: Bool, casOptions: CASOptions?) -> (success: Bool, diagnostics: [SWBUtil.Diagnostic]) {
        let result = LibSwiftDriver.createAndPlan(for: self, compilerLocation: compilerLocation, target: target, workingDirectory: workingDirectory, tempDirPath: tempDirPath, explicitModulesTempDirPath: explicitModulesTempDirPath, commandLine: args, environment: environment, eagerCompilationEnabled: eagerCompilationEnabled, casOptions: casOptions)
        if let driver = result.driver {
            do {
                try register(key: key, driver: driver)
                return (true, result.diagnostics)
            } catch {
                return (false, result.diagnostics + [SWBUtil.Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData(String(describing: error), component: .swiftCompilerError))])
            }
        } else {
            return (false, result.diagnostics)
        }
    }

    /// Query a previously planned build
    /// - Parameter key: A unique identifier which was used in the `planBuild` call as uniqueID
    /// - Throws: If build was not planned before, an error will be thrown
    /// - Returns: The driver wrapping instance for the given ID
    /// - Note: This method is thread safe and can be called multiple times on the same object
    public func queryPlannedBuild(for key: String) throws -> LibSwiftDriver.PlannedBuild {
        try registryQueue.blocking_sync {
            guard let driver = registry[key] else {
                throw StubError.error("Unable to find jobs for key \(key). Be sure to plan the build ahead of fetching results.")
            }
            return driver.plannedBuild
        }
    }

    public func querySwiftmodulesNeedingRegistrationForDebugging(for key: String) throws -> [String] {
        let driver = try registryQueue.blocking_sync {
            guard let driver = registry[key] else {
                throw StubError.error("Unable to find jobs for key \(key). Be sure to plan the build ahead of fetching results.")
            }
            return driver
        }
        #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
        if let cached = driver.cachedPlanQueryResults {
            return cached.swiftmodulesNeedingRegistration
        }
        #endif
        let graph = driver.intermoduleDependencyGraph
        guard let graph else { return [] }
        var swiftmodulePaths: [String] = []
        swiftmodulePaths.reserveCapacity(graph.modules.values.count)
        for (_, moduleInfo) in graph.modules.sorted(byKey: { $0.moduleName < $1.moduleName }) {
            guard moduleInfo != graph.mainModule else {
                continue
            }
            switch moduleInfo.details {
            case .swift:
                if let modulePath = VirtualPath.lookup(moduleInfo.modulePath.path).absolutePath {
                    swiftmodulePaths.append(modulePath.pathString)
                }
            case .swiftPrebuiltExternal(let details):
                if let modulePath = VirtualPath.lookup(details.compiledModulePath.path).absolutePath {
                    swiftmodulePaths.append(modulePath.pathString)
                }
            case .clang:
                fallthrough
            default:
                break
            }
        }
        return swiftmodulePaths
    }

    public func queryPlanningDependencies(for key: String) throws -> [String] {
        let driver = try registryQueue.blocking_sync {
            guard let driver = registry[key] else {
                throw StubError.error("Unable to find jobs for key \(key). Be sure to plan the build ahead of fetching results.")
            }
            return driver
        }
        #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
        if let cached = driver.cachedPlanQueryResults {
            return cached.planningDependencies
        }
        #endif
        let graph = driver.intermoduleDependencyGraph
        guard let graph else { return [] }
        var fileDependencies: [String] = []
        fileDependencies.reserveCapacity(graph.modules.values.count * 10)
        for (_, moduleInfo) in graph.modules.sorted(byKey: { $0.moduleName < $1.moduleName }) {
            guard moduleInfo != graph.mainModule else {
                continue
            }
            fileDependencies.append(contentsOf: moduleInfo.sourceFiles ?? [])
            switch moduleInfo.details {
            case .swiftPrebuiltExternal(let details):
                if let modulePath = VirtualPath.lookup(details.compiledModulePath.path).absolutePath {
                    fileDependencies.append(modulePath.pathString)
                }
            case .swift, .clang:
                fallthrough
            default:
                break
            }
        }
        return fileDependencies
    }

    public func queryTransitiveDependencyModuleNames(for key: String) async throws -> [String] {
        let driver = try await registryQueue.sync {
            guard let driver = self.registry[key] else {
                throw StubError.error("Unable to find jobs for key \(key). Be sure to plan the build ahead of fetching results.")
            }
            return driver
        }
        #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
        if let cached = driver.cachedPlanQueryResults {
            return cached.transitiveDependencyModuleNames
        }
        #endif
        let graph = driver.intermoduleDependencyGraph
        guard let graph else { return [] }
        // This calculation is a bit awkward because we cannot directly access the ID of the main module, just its info object
        let directDependencies = graph.mainModule.directDependencies ?? []
        let transitiveDependencies = Set(directDependencies + SWBUtil.transitiveClosure(directDependencies, successors: { moduleID in graph.modules[moduleID]?.directDependencies ?? [] }).0)
        return transitiveDependencies.map(\.moduleName)
    }

    #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
    @_spi(Testing) public var cachedPlanStagingHook: (() throws -> Void)?

    @_spi(Testing) public func reserveNativeTargetForTesting(_ outputs: [Path], token: String? = nil) throws -> String {
        let owner: UUID
        if let token {
            guard let parsed = UUID(uuidString: token) else { throw StubError.error("Malformed target reservation token.") }
            owner = parsed
        } else { owner = makeTargetToken() }
        try reserveTargetOutputs(outputs, token: owner)
        return owner.uuidString
    }

    @_spi(Testing) public func registerPlanForTesting(from key: String, as alias: String, lateOutputs: [Path]) throws {
        let driver = try registryQueue.blocking_sync {
            guard let driver = registry[key] else { throw StubError.error("Missing testing plan.") }
            return driver
        }
        try register(key: alias, driver: driver, beforePublication: { token in
            try self.reserveTargetOutputs(lateOutputs, token: token)
        })
    }

    @_spi(Testing) public func publicationStateForTesting() -> SWBUtil.ByteString {
        registryQueue.blocking_sync {
            let serializer = MsgPackSerializer()
            serializer.serialize(revision)
            serializer.serialize(registry.keys.sorted())
            serializer.serialize(globalExplicitDependencyTracker.plannedExplicitDependencyJobs)
            for path in outputOwners.keys.sorted() {
                serializer.serialize(path)
                switch outputOwners[path]! {
                case .target(let token): serializer.serialize(token.uuidString)
                case .explicit(let key): serializer.serialize(key)
                }
            }
            return serializer.byteString
        }
    }

    public func planCacheSnapshot(for key: String) async throws -> SwiftDriverPlanCacheSnapshot {
        let plannedBuild = try queryPlannedBuild(for: key)
        let base = plannedBuild.cacheSnapshot()
        // Record the transitive explicit-dependency closure: a job reused from an earlier target
        // can depend on jobs outside this target's own set (Reframe, C959).
        var keys = base.explicitModuleBuildJobKeys
        var frontier = Array(keys)
        while let next = frontier.popLast() {
            guard let job = plannedExplicitDependencyBuildJob(for: next) else { continue }
            for dependency in job.dependencies where !keys.contains(dependency) {
                keys.insert(dependency)
                frontier.append(dependency)
            }
        }
        let plan = keys == base.explicitModuleBuildJobKeys ? base
            : (base.closingExplicitDependencies(keys: keys, jobs: getExplicitDependencyBuildJobs(for: Array(keys).sorted())) ?? base)
        return SwiftDriverPlanCacheSnapshot(
            plannedBuild: plan,
            explicitModuleJobs: getExplicitDependencyBuildJobs(
                for: Array(plan.explicitModuleBuildJobKeys).sorted()
            ),
            swiftmodulesNeedingRegistration: try querySwiftmodulesNeedingRegistrationForDebugging(for: key),
            planningDependencies: try queryPlanningDependencies(for: key),
            transitiveDependencyModuleNames: try await queryTransitiveDependencyModuleNames(for: key),
            skippedCompileJobs: plannedBuild.skippedCompileJobsSnapshot()
        )
    }

    public func installCachedPlan(
        key: String,
        compilerLocation: LibSwiftDriver.CompilerLocation,
        target: ConfiguredTarget,
        args: [String],
        workingDirectory: Path,
        tempDirPath: Path,
        explicitModulesTempDirPath: Path,
        environment: [String: String],
        eagerCompilationEnabled: Bool,
        casOptions: CASOptions?,
        snapshot: SwiftDriverPlanCacheSnapshot
    ) throws {
        guard eagerCompilationEnabled else {
            throw StubError.error("Swift Driver plan replay currently requires eager compilation.")
        }
        guard snapshot.plannedBuild.workingDirectory == workingDirectory else {
            throw StubError.error("Cached Swift Driver working directory does not match the current task.")
        }
        // Snapshot graph state without entering any PlannedBuild queue; bounded optimistic retries.
        for _ in 0..<8 {
            let captured = registryQueue.blocking_sync { (revision, globalExplicitDependencyTracker, outputOwners) }
            let rebased = try snapshot.rebasedForReplay()
            var tracker = captured.1
            let mapping = try tracker.importingCachedJobs(rebased.explicitModuleJobs, workingDirectory: workingDirectory)
            let plan = try rebased.plannedBuild.remappingExplicitKeys(mapping)
            let staged = SwiftDriverPlanCacheSnapshot(
                plannedBuild: plan,
                explicitModuleJobs: tracker.getExplicitDependencyBuildJobs(for: Array(plan.explicitModuleBuildJobKeys).sorted()),
                swiftmodulesNeedingRegistration: rebased.swiftmodulesNeedingRegistration,
                planningDependencies: rebased.planningDependencies,
                transitiveDependencyModuleNames: rebased.transitiveDependencyModuleNames)
            var expectedProducers: [Path: LibSwiftDriver.JobKey] = [:]
            for job in staged.plannedBuild.plannedTargetJobs + staged.explicitModuleJobs {
                for output in job.driverJob.outputs { expectedProducers[output] = job.key }
            }
            guard expectedProducers == plan.producerMap,
                  Set(staged.explicitModuleJobs.map(\.key)) == plan.explicitModuleBuildJobKeys else {
                throw StubError.error("Cached producer map or explicit key coverage did not reproduce.")
            }
            var reservations = captured.2
            for job in tracker.plannedExplicitDependencyJobs {
                reservations = try reservingExplicit(job, jobs: { tracker.getExplicitDependencyBuildJobs(for: [$0]).first },
                                                     in: reservations)
            }
            let cachedDriver = try LibSwiftDriver(
                cachedPlan: staged,
                graph: self,
                compilerLocation: compilerLocation,
                target: target,
                workingDirectory: workingDirectory,
                tempDirPath: tempDirPath,
                explicitModulesTempDirPath: explicitModulesTempDirPath,
                commandLine: args,
                environment: environment,
                eagerCompilationEnabled: eagerCompilationEnabled,
                casOptions: casOptions
            )
            let targetPublication = cachedDriver.plannedBuild.targetOutputPublication()
            guard let token = targetPublication.token else { throw StubError.error("Missing cached target reservation token.") }
            reservations = try reserving(targetPublication.outputs, for: .target(token), in: reservations)
            try cachedPlanStagingHook?()
            let committed: Bool = try registryQueue.blocking_sync {
                guard registry[key] == nil, !issuedTargetTokens.contains(token) else {
                    throw StubError.error("Swift Driver graph changed during cached plan staging.")
                }
                // Another driver registered meanwhile (several targets replay at once in multi-file
                // edits, C963): restage from the new graph state instead of failing.
                guard revision == captured.0 else { return false }
                issuedTargetTokens.insert(token)
                globalExplicitDependencyTracker = tracker
                outputOwners = reservations
                registry[key] = cachedDriver
                revision += 1
                return true
            }
            if committed { return }
        }
        throw StubError.error("Swift Driver graph changed during cached plan staging.")
    }
    #endif

    /// Detach under the graph lock; incremental writes enter the plan queue and
    /// must run outside it. Keep reservations for late callbacks.
    public func cleanUpForAllKeys() -> [SWBUtil.Diagnostic] {
        let drivers = registryQueue.blocking_sync {
            let drivers = Array(registry.values)
            registry.removeAll()
            revision += 1
            return drivers
        }
        return drivers.flatMap { $0.writeIncrementalBuildInformation() }
    }

    public func cleanUp(key: String) -> [SWBUtil.Diagnostic] {
        let driver = registryQueue.blocking_sync {
            let driver = registry.removeValue(forKey: key)
            revision += 1
            return driver
        }
        return driver?.writeIncrementalBuildInformation() ?? []
    }

    /// Get the CASDatabases from the casOptions
    public func getCASDatabases(casOptions: CASOptions?, compilerLocation: LibSwiftDriver.CompilerLocation) throws -> SwiftCASDatabases? {
        guard let casOpts = casOptions else { return nil }
        return try createCASDatabases(casOptions: casOpts, compilerLocation: compilerLocation)
    }

    #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
    package static let acceleratorReplayLibSwiftScanEnvironmentKey = "SWIFTBUILD_INTERNAL_REPLAY_LIBSWIFTSCAN_PATH"

    package static func acceleratorReplayLibSwiftScanPath(environment: [String: String]) throws -> Path? {
        guard let value = environment[acceleratorReplayLibSwiftScanEnvironmentKey] else {
            return nil
        }
        guard !value.isEmpty else {
            throw StubError.error("\(acceleratorReplayLibSwiftScanEnvironmentKey) must not be empty")
        }
        let path = Path(value)
        guard path.isAbsolute else {
            throw StubError.error("\(acceleratorReplayLibSwiftScanEnvironmentKey) must be absolute")
        }
        return path
    }

    /// Returns a CAS owned entirely by the replay-only scanner. This does not
    /// modify Swift Driver's environment or the scanner used to plan modules.
    public func getAcceleratorReplayCASDatabases(
        casOptions: CASOptions,
        compilerLocation: LibSwiftDriver.CompilerLocation
    ) throws -> SwiftCASDatabases? {
        try getAcceleratorReplayCASDatabases(
            casOptions: casOptions,
            compilerLocation: compilerLocation,
            environment: ProcessInfo.processInfo.environment
        )
    }

    package func getAcceleratorReplayCASDatabases(
        casOptions: CASOptions,
        compilerLocation: LibSwiftDriver.CompilerLocation,
        environment: [String: String]
    ) throws -> SwiftCASDatabases? {
        guard let libSwiftScanPath = try Self.acceleratorReplayLibSwiftScanPath(environment: environment) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: libSwiftScanPath.str) else {
            throw StubError.error("\(Self.acceleratorReplayLibSwiftScanEnvironmentKey) does not exist: \(libSwiftScanPath.str)")
        }
        return try createAcceleratorReplayCASDatabases(
            casOptions: casOptions,
            compilerLocation: compilerLocation,
            libSwiftScanPath: libSwiftScanPath
        )
    }
    #endif

    private func register(key: String, driver: LibSwiftDriver, beforePublication: ((UUID) throws -> Void)? = nil) throws {
        let publication = driver.plannedBuild.targetOutputPublication()
        guard let token = publication.token else { throw StubError.error("Missing native target reservation token.") }
        try beforePublication?(token)
        try registryQueue.blocking_sync {
            guard registry[key] == nil, issuedTargetTokens.contains(token) else { throw StubError.error("Duplicate Swift Driver target registration.") }
            let reservations = try reserving(publication.outputs, for: .target(token), in: outputOwners)
            outputOwners = reservations
            registry[key] = driver
            revision += 1
        }
    }

    public func addExplicitDependencyBuildJobs(_ jobs: [SwiftDriverJob], workingDirectory: Path,
                                               producerMap: inout [Path: LibSwiftDriver.JobKey]) throws -> Set<LibSwiftDriver.JobKey> {
        try registryQueue.blocking_sync {
            var tracker = globalExplicitDependencyTracker
            var producers = producerMap
            let keys = try tracker.addExplicitDependencyBuildJobs(jobs, workingDirectory: workingDirectory, producerMap: &producers)
            var reservations = outputOwners
            for job in tracker.getExplicitDependencyBuildJobs(for: Array(keys).sorted()) {
                reservations = try reservingExplicit(job, jobs: { tracker.getExplicitDependencyBuildJobs(for: [$0]).first },
                                                     in: reservations)
            }
            globalExplicitDependencyTracker = tracker
            outputOwners = reservations
            producerMap = producers
            revision += 1
            return keys
        }
    }
    public func getExplicitDependencyBuildJobs(for keys: [LibSwiftDriver.JobKey]) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] {
        registryQueue.blocking_sync {
            globalExplicitDependencyTracker.getExplicitDependencyBuildJobs(for: keys)
        }
    }
    public func plannedExplicitDependencyBuildJob(for key: LibSwiftDriver.JobKey) -> LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob? {
        registryQueue.blocking_sync {
            globalExplicitDependencyTracker.plannedExplicitDependencyBuildJob(for: key)
        }
    }
    public func explicitDependencies(for job: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] {
        registryQueue.blocking_sync {
            globalExplicitDependencyTracker.explicitDependencies(for: job)
        }
    }

    public var isEmpty: Bool {
        registryQueue.blocking_sync {
            globalExplicitDependencyTracker.plannedExplicitDependencyJobs.isEmpty
        }
    }

    public func generatePrecompiledModulesReport(in directory: Path, fs: any FSProxy) async throws -> String {
        // Collect DependencyInfo of every module built during the current build.
        var jobsByModuleID: [String: [SwiftDriverJob]] = [:]
        for job in globalExplicitDependencyTracker.plannedExplicitDependencyJobs {
            let qualifier: String
            switch job.driverJob.ruleInfoType {
            case "CompileModuleFromInterface":
                qualifier = "(Swift)"
            case "GeneratePcm":
                qualifier = "(Clang)"
            default:
                qualifier = "(Unknown)"
            }
            jobsByModuleID["\(job.driverJob.moduleName) \(qualifier)", default: []].append(job.driverJob)
        }

        var summaryCSV = CSVBuilder()
        summaryCSV.writeRow(["Name", "Variants"])
        var summaryMessage = ""

        for (moduleID, jobs) in jobsByModuleID.sorted(by: \.0) {
            summaryCSV.writeRow([moduleID, "\(jobs.count)"])
            summaryMessage += "\(moduleID): \(jobs.count == 1 ? "1 variant" : "\(jobs.count) variants")\n"

            let mergeResult = nWayMerge(jobs.map { $0.commandLine.filter {
                if ["pcm", "dia", "d"].contains(Path($0).fileExtension) {
                    // Filter differences in module paths, they are a function of the other args
                    return false
                } else if $0.hasPrefix("llvmcas://") {
                    // Filter differences in CAS URLs, they are a function of the other args
                    return false
                } else {
                    return true
                }
            }.map { $0.asString } }).filter {
                if $0.elementOf.count == jobs.count {
                    // Don't report args common to all variants
                    return false
                } else {
                    return true
                }
            }

            var moduleCSV = CSVBuilder()
            moduleCSV.writeRow(["Variant"] + mergeResult.map(\.element))

            for (idx, job) in jobs.enumerated() {
                let jobID = job.outputs.only?.basename ?? "Unknown"
                var checkboxes: [String] = []
                for mergeElement in mergeResult {
                    if mergeElement.elementOf.contains(idx) {
                        checkboxes.append("✅")
                    } else {
                        checkboxes.append("❌")
                    }
                }
                moduleCSV.writeRow([jobID] + checkboxes)
            }

            try fs.write(directory.join("\(moduleID).csv"), contents: ByteString(encodingAsUTF8: moduleCSV.output))
        }
        try fs.write(directory.join("Summary.csv"), contents: ByteString(encodingAsUTF8: summaryCSV.output))
        summaryMessage += "\nFull report written to '\(directory.str)'"
        return summaryMessage
    }
}

class Executor: DriverExecutor {
    let resolver: ArgsResolver
    let explicitModulesResolver: ArgsResolver
    let fileSystem: any FileSystem
    let env: [String: String]
    let eagerCompilationEnabled: Bool
    private(set) weak var explicitDependencyGraph: (any SwiftGlobalExplicitDependencyGraph)?
    let workingDirectory: Path

    private var plannedBuild: LibSwiftDriver.PlannedBuild?

    init(resolver: ArgsResolver, explicitModulesResolver: ArgsResolver, explicitDependencyGraph: (any SwiftGlobalExplicitDependencyGraph)?, workingDirectory: Path, fileSystem: any FileSystem, env: [String: String], eagerCompilationEnabled: Bool) {
        self.resolver = resolver
        self.explicitModulesResolver = explicitModulesResolver
        self.explicitDependencyGraph = explicitDependencyGraph
        self.fileSystem = fileSystem
        self.env = env
        self.eagerCompilationEnabled = eagerCompilationEnabled
        self.workingDirectory = workingDirectory
    }

    func execute(job: Job, forceResponseFiles: Bool, recordedInputModificationDates: [TypedVirtualPath : TimePoint]) throws -> ProcessResult {
        let useResponseFiles : ResponseFileHandling = forceResponseFiles ? .forced : .heuristic
        let arguments: [String] = try resolver.resolveArgumentList(for: job,
                                                                   useResponseFiles: useResponseFiles)

        try job.verifyInputsNotModified(since: recordedInputModificationDates, fileSystem: fileSystem)

        if job.requiresInPlaceExecution {
            for (envVar, value) in job.extraEnvironmentBlock {
                try ProcessEnv.setVar(envVar.value, value: value)
            }

            try exec(path: arguments[0], args: arguments)
        } else {
            var childEnv = ProcessEnvironmentBlock()
            for (key, value) in env {
                childEnv[ProcessEnvironmentKey(key)] = value
            }
            childEnv.merge(job.extraEnvironmentBlock, uniquingKeysWith: { (_, new) in new })

            let process = try Process.launchProcess(arguments: arguments, env: childEnv)
            return try process.waitUntilExit()
        }
    }

    func execute(workload: DriverExecutorWorkload, delegate: any JobExecutionDelegate, numParallelJobs: Int, forceResponseFiles: Bool, recordedInputModificationDates: [TypedVirtualPath : TimePoint]) throws {
        guard self.plannedBuild == nil else {
            throw StubError.error("Unexpected extra workload from Swift driver.")
        }
        self.plannedBuild = try LibSwiftDriver.PlannedBuild(workload: workload, argsResolver: self.resolver, explicitModulesResolver: self.explicitModulesResolver, jobExecutionDelegate: delegate, globalExplicitDependencyJobGraph: explicitDependencyGraph, workingDirectory: workingDirectory, eagerCompilationEnabled: eagerCompilationEnabled)
    }

    func checkNonZeroExit(args: String..., environment: [String : String]) throws -> String {
        try Process.checkNonZeroExit(arguments: args, environmentBlock: .init(environment))
    }

    /// Moves the ownership of the plannedBuild to the caller and clears internal state.
    func movePlannedBuild() -> LibSwiftDriver.PlannedBuild? {
        let plannedBuild = self.plannedBuild
        self.plannedBuild = nil
        return plannedBuild
    }

    func description(of job: Job, forceResponseFiles: Bool) throws -> String {
        let ruleInfoType = job.kind.rawValue.capitalized
        let moduleName = job.moduleName
        let inputs = job.displayInputs.map(\.file.basename)
        return ([ruleInfoType, moduleName] + inputs).joined(separator: " ")
    }
}

/// The class that wraps the Swift driver and provides a namespace for PlannedBuild
public final class LibSwiftDriver {
    public typealias JobIndex = Int
    /// Type to fetch dependencies of planned jobs
    public enum JobKey : Comparable, Hashable, Serializable {
        case explicitDependencyJob(_ index: JobIndex)
        case targetJob(_ index: JobIndex)

        public func serialize<T>(to serializer: T) where T : Serializer {
            serializer.beginAggregate(2)
            switch self {
                case .explicitDependencyJob(let index):
                    serializer.serialize(0)
                    serializer.serialize(index)
                case .targetJob(let index):
                    serializer.serialize(1)
                    serializer.serialize(index)
            }
            serializer.endAggregate()
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            let code: Int = try deserializer.deserialize()
            switch code {
                case 0:
                    let index: JobIndex = try deserializer.deserialize()
                    self = .explicitDependencyJob(index)
                case 1:
                    let index: JobIndex = try deserializer.deserialize()
                    self = .targetJob(index)
                default:
                    throw DeserializerError.incorrectType("Unexpected type code for LibSwiftDriver.JobKey: \(code)")
            }
        }
    }

    public enum CompilerLocation: SerializableCodable, CustomStringConvertible, Hashable, Sendable {
        case path(Path)
        case library(libSwiftScanPath: Path)

        public var compilerOrLibraryPath: Path {
            switch self {
            case .path(let path):
                return path
            case .library(let path):
                return path
            }
        }

        public var description: String {
            switch self {
            case .path(let path):
                return path.str
            case .library:
                return "library"
            }
        }
    }

    /// The target this build is part of
    public let target: ConfiguredTarget?
    /// The directory which gets used to resolve relative paths
    public let workingDirectory: Path
    /// The directory which gets used to store modules
    public let tempDirPath: Path
    /// The command line to build the module
    public let commandLine: [String]
    /// Indicates if the driver will create jobs for emitting modules which unblock downstream targets
    public let eagerCompilationEnabled: Bool
    /// Compiler location for the build
    public let compilerLocation: CompilerLocation

    private let resolver: ArgsResolver
    private let explicitModulesResolver: ArgsResolver
    private let executor: Executor
    private var driver: SwiftDriver.Driver?
    private let diagnosticsEngine: TSCBasic.DiagnosticsEngine?

    #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
    fileprivate let cachedPlanQueryResults: SwiftDriverPlanCacheSnapshot?
    #endif

    private var _plannedBuild: PlannedBuild?

    public var plannedBuild: PlannedBuild {
        if let build = _plannedBuild {
            return build
        }
        // If the executor has no planned build at this stage, there were no jobs to execute
        return try! PlannedBuild(workload: .all([]), argsResolver: self.resolver, explicitModulesResolver: self.explicitModulesResolver, jobExecutionDelegate: nil, globalExplicitDependencyJobGraph: nil, workingDirectory: workingDirectory, eagerCompilationEnabled: self.eagerCompilationEnabled)
    }

    var intermoduleDependencyGraph: InterModuleDependencyGraph?

    /// Keep the exact search-path spelling in cached frontend jobs: these paths
    /// are serialized for LLDB even though explicit imports do not search them.
    /// Adapt before Driver planning so the compiler CAS keys include the paths.
    package static func preservingDebuggerSearchPaths(
        _ args: [String], diagnosticsEngine: TSCBasic.DiagnosticsEngine
    ) throws -> [String] {
        #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
        let expanded = try Driver.expandResponseFiles(args, fileSystem: localFileSystem, diagnosticsEngine: diagnosticsEngine)
        var options = try OptionTable().parse(Array(expanded.dropFirst()), for: .batch, delayThrows: true)
        guard options.contains(.cacheCompileJob), options.contains(.driverExplicitModuleBuild),
              options.arguments(for: .Xfrontend).contains(where: { $0.argument.asSingle == "-serialize-debugging-options" }) else {
            return args
        }
        let paths = options.arguments(for: .I, .Isystem, .F, .Fsystem)
        let forwarded = paths.flatMap { ["-Xfrontend", $0.option.spelling, "-Xfrontend", $0.argument.asSingle] }
        // Prepend after the executable so a trailing '--' cannot turn options
        // into inputs. Leave original response files and scanner paths intact.
        return Array(args.prefix(1)) + forwarded + Array(args.dropFirst())
        #else
        return args
        #endif
    }

    private init(graph: SwiftModuleDependencyGraph?, compilerLocation: CompilerLocation, target: ConfiguredTarget?, workingDirectory: Path, tempDirPath: Path, explicitModulesTempDirPath: Path, commandLine: [String], environment: [String: String], eagerCompilationEnabled: Bool, diagnosticsEngine: TSCBasic.DiagnosticsEngine, casOptions: CASOptions?) throws {
        self.target = target
        self.workingDirectory = workingDirectory
        self.tempDirPath = tempDirPath
        self.commandLine = commandLine
        self.compilerLocation = compilerLocation

        // Public API should not expose SwiftDriver types so do the mapping here.
        self.eagerCompilationEnabled = eagerCompilationEnabled
        // rdar://91153940 Inject file system, diagnostics engine and environment
        let fileSystem = localFileSystem
        self.resolver = try ArgsResolver(fileSystem: fileSystem, temporaryDirectory: VirtualPath(path: tempDirPath.str))
        self.explicitModulesResolver = try ArgsResolver(fileSystem: fileSystem, temporaryDirectory: VirtualPath(path: explicitModulesTempDirPath.str))
        self.executor = Executor(resolver: resolver, explicitModulesResolver: explicitModulesResolver, explicitDependencyGraph: graph, workingDirectory: workingDirectory, fileSystem: fileSystem, env: environment, eagerCompilationEnabled: eagerCompilationEnabled)
        self.diagnosticsEngine = diagnosticsEngine
        #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
        self.cachedPlanQueryResults = nil
        #endif
        var env = ProcessEnvironmentBlock()
        let compilerExecutableDir: TSCBasic.AbsolutePath?
        switch compilerLocation {
        case .path(let path):
            for (key, value) in environment {
                env[ProcessEnvironmentKey(key)] = value
            }
            #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
            if let override = ProcessInfo.processInfo.environment["SWIFTBUILD_INTERNAL_LIBSWIFTSCAN_PATH"] {
                let overridePath = Path(override)
                guard overridePath.isAbsolute else {
                    throw StubError.error("SWIFTBUILD_INTERNAL_LIBSWIFTSCAN_PATH must be absolute")
                }
                guard FileManager.default.fileExists(atPath: overridePath.str) else {
                    throw StubError.error("SWIFTBUILD_INTERNAL_LIBSWIFTSCAN_PATH does not exist: \(overridePath.str)")
                }
                env[ProcessEnvironmentKey("SWIFT_DRIVER_SWIFTSCAN_LIB")] = overridePath.str
            }
            #endif
            compilerExecutableDir = try TSCBasic.AbsolutePath(validating: path.dirname.str)
        case .library(libSwiftScanPath: let path):
            // Remove lib/swift/host/lib_InternalSwiftScan.dylib and add bin/swift-frontend to get a fake path to the compiler frontend.
            let fakeFrontendPath = path.dirname.dirname.dirname.dirname.join("bin/swift-frontend")
            for (key, value) in environment {
                env[ProcessEnvironmentKey(key)] = value
            }
            env.merge(["SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": fakeFrontendPath.str, "SWIFT_DRIVER_SWIFTSCAN_LIB": path.str], uniquingKeysWith: { first, second in first })
            compilerExecutableDir = try TSCBasic.AbsolutePath(validating: fakeFrontendPath.dirname.str)
        }
        let key = SwiftModuleDependencyGraph.OracleRegistryKey(compilerLocation: compilerLocation, casOpts: casOptions)
        let oracle = graph?.oracleRegistry.getOrInsert(key, { InterModuleDependencyOracle() })
        let driver = try Driver(args: Self.preservingDebuggerSearchPaths(commandLine, diagnosticsEngine: diagnosticsEngine), envBlock: env, diagnosticsOutput: .engine(diagnosticsEngine), executor: executor, compilerIntegratedTooling: false, compilerExecutableDir: compilerExecutableDir, interModuleDependencyOracle: oracle)
        self.driver = driver
        if let scanOracle = oracle, let scanLib = try driver.getSwiftScanLibPath() {
            // Errors instantiating the scanner are potentially recoverable, so suppress them here. Truly fatal errors
            // will be diagnosed later.
            try? scanOracle.verifyOrCreateScannerInstance(swiftScanLibPath: scanLib)
        }
    }

    #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
    fileprivate init(
        cachedPlan: SwiftDriverPlanCacheSnapshot,
        graph: SwiftModuleDependencyGraph,
        compilerLocation: CompilerLocation,
        target: ConfiguredTarget,
        workingDirectory: Path,
        tempDirPath: Path,
        explicitModulesTempDirPath: Path,
        commandLine: [String],
        environment: [String: String],
        eagerCompilationEnabled: Bool,
        casOptions: CASOptions?
    ) throws {
        self.target = target
        self.workingDirectory = workingDirectory
        self.tempDirPath = tempDirPath
        self.commandLine = commandLine
        self.eagerCompilationEnabled = eagerCompilationEnabled
        self.compilerLocation = compilerLocation
        let fileSystem = localFileSystem
        self.resolver = try ArgsResolver(
            fileSystem: fileSystem,
            temporaryDirectory: VirtualPath(path: tempDirPath.str)
        )
        self.explicitModulesResolver = try ArgsResolver(
            fileSystem: fileSystem,
            temporaryDirectory: VirtualPath(path: explicitModulesTempDirPath.str)
        )
        self.executor = Executor(
            resolver: resolver,
            explicitModulesResolver: explicitModulesResolver,
            explicitDependencyGraph: graph,
            workingDirectory: workingDirectory,
            fileSystem: fileSystem,
            env: environment,
            eagerCompilationEnabled: eagerCompilationEnabled
        )
        let diagnosticsEngine = TSCBasic.DiagnosticsEngine(handlers: [])
        self.diagnosticsEngine = diagnosticsEngine
        var processEnvironment = ProcessEnvironmentBlock()
        let compilerExecutableDir: TSCBasic.AbsolutePath?
        switch compilerLocation {
        case .path(let path):
            for (key, value) in environment {
                processEnvironment[ProcessEnvironmentKey(key)] = value
            }
            compilerExecutableDir = try TSCBasic.AbsolutePath(validating: path.dirname.str)
        case .library(libSwiftScanPath: let path):
            let fakeFrontendPath = path.dirname.dirname.dirname.dirname.join("bin/swift-frontend")
            for (key, value) in environment {
                processEnvironment[ProcessEnvironmentKey(key)] = value
            }
            processEnvironment.merge(
                [
                    "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": fakeFrontendPath.str,
                    "SWIFT_DRIVER_SWIFTSCAN_LIB": path.str,
                ],
                uniquingKeysWith: { first, _ in first }
            )
            compilerExecutableDir = try TSCBasic.AbsolutePath(validating: fakeFrontendPath.dirname.str)
        }
        let oracleKey = SwiftModuleDependencyGraph.OracleRegistryKey(
            compilerLocation: compilerLocation,
            casOpts: casOptions
        )
        let oracle = graph.oracleRegistry.getOrInsert(
            oracleKey,
            { InterModuleDependencyOracle() }
        )
        let driver = try Driver(
            args: Self.preservingDebuggerSearchPaths(commandLine, diagnosticsEngine: diagnosticsEngine),
            envBlock: processEnvironment,
            diagnosticsOutput: .engine(diagnosticsEngine),
            executor: executor,
            compilerIntegratedTooling: false,
            compilerExecutableDir: compilerExecutableDir,
            interModuleDependencyOracle: oracle
        )
        self.driver = driver
        if let scanLib = try driver.getSwiftScanLibPath() {
            try? oracle.verifyOrCreateScannerInstance(swiftScanLibPath: scanLib)
        }
        self._plannedBuild = PlannedBuild(
            cacheSnapshot: cachedPlan.plannedBuild,
            argsResolver: resolver,
            explicitModulesResolver: explicitModulesResolver,
            globalExplicitDependencyJobGraph: graph,
            targetReservationToken: UUID()
        )
        self.intermoduleDependencyGraph = nil
        self.cachedPlanQueryResults = cachedPlan
    }
    #endif

    private func run(dryRun: Bool = false) -> (success: Bool, diagnostics: [SWBUtil.Diagnostic], jobs: [Job]) {
        guard var driver, let diagnosticsEngine else {
            return (
                false,
                [SWBUtil.Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Cached Swift Driver cannot execute the normal planning path.", component: .swiftCompilerError))],
                []
            )
        }
        defer { self.driver = driver }
        let driverDiagnostics: () -> [SWBUtil.Diagnostic] = {
            driver.diagnosticEngine.diagnostics.map({ .build(from: $0) })
        }

        do {
            let jobs = try driver.planBuild()
            if !dryRun {
                try driver.run(jobs: jobs)
                if let plannedBuild = executor.movePlannedBuild() {
                    _plannedBuild = plannedBuild
                    intermoduleDependencyGraph = driver.intermoduleDependencyGraph
                } else {
                    throw StubError.error("Swift driver build planning failed")
                }
            }
            return (true, driverDiagnostics(), jobs)
        } catch {
            let fallbackDiagnostics: [SWBUtil.Diagnostic]
            if driver.diagnosticEngine.hasErrors {
                #if canImport(os)
                OSLog.log("Driver threw error \(error) but emitted errors to build log.")
                #endif
                fallbackDiagnostics = []
            } else {
                fallbackDiagnostics = [SWBUtil.Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData(error.localizedDescription, component: .swiftCompilerError))]
            }
            return (false, fallbackDiagnostics + driverDiagnostics(), [])
        }
    }

    /// Serializes incremental build state and returns any diagnostics emitted during serialization
    /// (e.g. "next compile won't be incremental"). Uses a snapshot-delta of the accumulated
    /// diagnostics engine so only diagnostics produced by this call are returned.
    public func writeIncrementalBuildInformation() -> [SWBUtil.Diagnostic] {
        guard var driver, let diagnosticsEngine else { return [] }
        defer { self.driver = driver }
        let beforeCount = diagnosticsEngine.diagnostics.count
        driver.writeIncrementalBuildInformation(plannedBuild.driverTargetJobs)
        return diagnosticsEngine.diagnostics.dropFirst(beforeCount).map { .build(from: $0) }
    }

    static func frontendCommandLine(compilerLocation: CompilerLocation, inputPath: Path, workingDirectory: Path, tempDirPath: Path, explicitModulesTempDirPath: Path, commandLine: [String], environment: [String: String], eagerCompilationEnabled: Bool, casOptions: CASOptions?) -> (commandLine: [String]?, diagnostics: [SWBUtil.Diagnostic]) {
        let diagnosticsEngine = TSCBasic.DiagnosticsEngine(handlers: [])
        do {
            let shim = try LibSwiftDriver(graph: nil, compilerLocation: compilerLocation, target: nil, workingDirectory: workingDirectory, tempDirPath: tempDirPath, explicitModulesTempDirPath: explicitModulesTempDirPath, commandLine: commandLine, environment: environment, eagerCompilationEnabled: eagerCompilationEnabled, diagnosticsEngine: diagnosticsEngine, casOptions: casOptions)
            let (success, diagnostics, jobs) = shim.run(dryRun: true)
            if !success {
                return (nil, diagnostics)
            }
            guard let job = jobs.filter({ job in
                job.primarySwiftSourceFiles.contains(where: { $0.typedFile.file.absolutePath?.pathString == inputPath.str })
            }).only else {
                return (nil, diagnostics)
            }
            let resolvedCommandLine: [String] = try shim.resolver.resolveArgumentList(for: job, useResponseFiles: .heuristic)
            return (resolvedCommandLine, diagnostics)
        } catch {
            let diagnostics = diagnosticsEngine.diagnostics.map({ SWBUtil.Diagnostic.build(from: $0) })

            if diagnosticsEngine.hasErrors {
                #if canImport(os)
                OSLog.log("Driver threw error \(error) but emitted errors to build log.")
                #endif
                return (nil, diagnostics)
            } else {
                let fallbackDiagnostic = SWBUtil.Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Driver threw \(error) without emitting errors.", component: .swiftCompilerError))
                return (nil, diagnostics + [fallbackDiagnostic])
            }
        }
    }

    fileprivate static func createAndPlan(for graph: SwiftModuleDependencyGraph, compilerLocation: CompilerLocation, target: ConfiguredTarget, workingDirectory: Path, tempDirPath: Path, explicitModulesTempDirPath: Path, commandLine: [String], environment: [String: String], eagerCompilationEnabled: Bool, casOptions: CASOptions?) -> (driver: LibSwiftDriver?, diagnostics: [SWBUtil.Diagnostic]) {
        let diagnosticsEngine = TSCBasic.DiagnosticsEngine(handlers: [])

        do {
            let shim = try LibSwiftDriver(graph: graph, compilerLocation: compilerLocation, target: target, workingDirectory: workingDirectory, tempDirPath: tempDirPath, explicitModulesTempDirPath: explicitModulesTempDirPath, commandLine: commandLine, environment: environment, eagerCompilationEnabled: eagerCompilationEnabled, diagnosticsEngine: diagnosticsEngine, casOptions: casOptions)
            let (success, diagnostics, _) = shim.run()
            guard success, !diagnosticsEngine.hasErrors else {
                return (nil, diagnostics)
            }
            return (shim, diagnostics)
        } catch {
            let diagnostics = diagnosticsEngine.diagnostics.map({ SWBUtil.Diagnostic.build(from: $0) })

            if diagnosticsEngine.hasErrors {
                #if canImport(os)
                OSLog.log("Driver threw error \(error) but emitted errors to build log.")
                #endif
                return (nil, diagnostics)
            } else {
                let fallbackDiagnostic = SWBUtil.Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Driver threw \(error) without emitting errors.", component: .swiftCompilerError))
                return (nil, diagnostics + [fallbackDiagnostic])
            }
        }
    }
}

extension LibSwiftDriver {
    static let supportedOptionSpellings = Set(SwiftOptions.Option.allOptions.map(\.spelling))
    public static func supportsDriverFlag(spelled spelling: String) -> Bool {
        Self.supportedOptionSpellings.contains(spelling)
    }
}

// MARK: Wrappers for SwiftDriver CAS types

extension SwiftModuleDependencyGraph {
    /// Create the CASDatabases from CASOptions
    private func createCASDatabases(casOptions: CASOptions, compilerLocation: LibSwiftDriver.CompilerLocation) throws -> SwiftCASDatabases {
        func toAbsolutePath(_ path: String?) throws -> TSCBasic.AbsolutePath? {
            guard let path else { return nil }
            return try AbsolutePath(validating: path)
        }
        let pluginOpts = casOptions.pluginOptions(useRemote: true)
        let key = SwiftModuleDependencyGraph.OracleRegistryKey(compilerLocation: compilerLocation, casOpts: casOptions)
        guard let oracle = oracleRegistry[key] else {
            throw StubError.error("can't find created dependency scanning oracle from compiler location \(compilerLocation)")
        }
        let cas = try oracle.getOrCreateCAS(pluginPath: try toAbsolutePath(casOptions.pluginPath?.str),
                                            onDiskPath: try toAbsolutePath(casOptions.casPath.str),
                                            pluginOptions: pluginOpts)
        return SwiftCASDatabases(cas)
    }

    #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
    /// Creates a second, replay-only scanner/CAS owner. Only string cache keys
    /// and frontend command lines enter this boundary; opaque values obtained
    /// from Apple's scanner are never passed to this oracle.
    private func createAcceleratorReplayCASDatabases(
        casOptions: CASOptions,
        compilerLocation: LibSwiftDriver.CompilerLocation,
        libSwiftScanPath: Path
    ) throws -> SwiftCASDatabases {
        func toAbsolutePath(_ path: String?) throws -> TSCBasic.AbsolutePath? {
            guard let path else { return nil }
            return try TSCBasic.AbsolutePath(validating: path)
        }

        let key = AcceleratorReplayOracleRegistryKey(
            compilerLocation: compilerLocation,
            libSwiftScanPath: libSwiftScanPath,
            casOpts: casOptions
        )
        let oracle = acceleratorReplayOracleRegistry.getOrInsert(key, {
            InterModuleDependencyOracle()
        })
        try oracle.verifyOrCreateScannerInstance(
            swiftScanLibPath: TSCBasic.AbsolutePath(validating: libSwiftScanPath.str)
        )
        let cas = try oracle.getOrCreateCAS(
            pluginPath: try toAbsolutePath(casOptions.pluginPath?.str),
            onDiskPath: try toAbsolutePath(casOptions.casPath.str),
            pluginOptions: casOptions.pluginOptions(useRemote: true)
        )
        return SwiftCASDatabases(cas)
    }
    #endif
}

/// SwiftCachedCompilation wraps CachedCompilation from SwiftDriver
public final class SwiftCachedCompilation {
    let cachedCompilation: CachedCompilation
    public let key: String
    init(_ cachedCompilation: CachedCompilation, key: String) {
        self.cachedCompilation = cachedCompilation
        self.key = key
    }

    public var outputsCount: UInt32 {
        cachedCompilation.count
    }
    public var isUncacheable: Bool {
        cachedCompilation.isUncacheable
    }

    public func getOutputs() throws -> [SwiftCachedOutput] {
        try cachedCompilation.map {
            try SwiftCachedOutput($0)
        }
    }

    public func makeGlobal() async throws {
        try await cachedCompilation.makeGlobal()
    }

    public func makeGlobal(_ callback: @escaping ((any Swift.Error)?) -> Void) {
        cachedCompilation.makeGlobal(callback)
    }
}

/// SwiftCachedOutput wraps CachedOutput from SwiftDriver
public final class SwiftCachedOutput {
    let cachedOutput: CachedOutput

    public let casID: String
    public let kindName: String

    init(_ cachedOutput: CachedOutput) throws {
        self.cachedOutput = cachedOutput
        self.casID = try cachedOutput.getCASID()
        self.kindName = try cachedOutput.getOutputKindName()
    }

    public var isMaterialized: Bool {
        cachedOutput.isMaterialized
    }
    public func load() async throws -> Bool {
        try await cachedOutput.load()
    }
}

/// SwiftCacheReplayInstance wraps CacheReplayInstance from SwiftDriver
public final class SwiftCacheReplayInstance {
    let cacheReplayInstance: CacheReplayInstance
    init(_ cacheReplayInstance: CacheReplayInstance) {
        self.cacheReplayInstance = cacheReplayInstance
    }
}

/// SwiftCacheReplayResult wraps CacheReplayResult from SwiftDriver
public final class SwiftCacheReplayResult {
    let cacheReplayResult: CacheReplayResult
    init(_ cacheReplayResult: CacheReplayResult) {
        self.cacheReplayResult = cacheReplayResult
    }

    public func getStdOut() throws -> String {
        try self.cacheReplayResult.getStdOut()
    }
    public func getStdErr() throws -> String {
        try self.cacheReplayResult.getStdErr()
    }
}

/// SwiftCASDatabases wraps SwiftScanCAS that provides a CAS database interface
public final class SwiftCASDatabases {
    let cas: SwiftScanCAS
    init(_ cas: SwiftScanCAS) {
        self.cas = cas
    }

    public var supportsSizeManagement: Bool { cas.supportsSizeManagement }

    public func getStorageSize() throws -> Int64? { try cas.getStorageSize() }

    public func setSizeLimit(_ size: Int64) throws { try cas.setSizeLimit(size) }

    public func prune() throws { try cas.prune() }

    public func queryCacheKey(_ key: String, globally: Bool) async throws -> SwiftCachedCompilation? {
        guard let comp = try await cas.queryCacheKey(key, globally: globally) else { return nil }
        return SwiftCachedCompilation(comp, key: key)
    }

    /// synchronized query local cache only.
    public func queryLocalCacheKey(_ key: String) throws -> SwiftCachedCompilation? {
        guard let comp = try cas.queryCacheKey(key, globally: false) else { return nil }
        return SwiftCachedCompilation(comp, key: key)
    }

    public func createReplayInstance(cmd: [String]) throws -> SwiftCacheReplayInstance {
        return SwiftCacheReplayInstance(try cas.createReplayInstance(commandLine: cmd))
    }

    public func replayCompilation(instance: SwiftCacheReplayInstance, compilation: SwiftCachedCompilation) throws -> SwiftCacheReplayResult {
        return SwiftCacheReplayResult(try cas.replayCompilation(instance: instance.cacheReplayInstance, compilation: compilation.cachedCompilation))
    }

    public func download(with id: String) async throws -> Bool {
        return try await cas.download(with: id)
    }
}

extension SWBUtil.Diagnostic {
    fileprivate static func build(from other: TSCBasic.Diagnostic) -> Self {
        let location: SWBUtil.Diagnostic.Location
        if let scannerLocation = other.location as? ScannerDiagnosticSourceLocation {
            location = .path(Path(scannerLocation.bufferIdentifier), line: scannerLocation.lineNumber, column: scannerLocation.columnNumber)
        } else {
            location = .unknown
        }
        return SWBUtil.Diagnostic(behavior: .build(from: other.behavior), location: location, data: DiagnosticData(other.message.text, component: .swiftCompilerError))
    }
}

extension SWBUtil.Diagnostic.Behavior {
    fileprivate static func build(from other: TSCBasic.Diagnostic.Behavior) -> Self {
        switch other {
        case .error:
            return .error
        case .warning:
            return .warning
        case .note:
            return .note
        case .remark:
            return .remark
        case .ignored:
            return .ignored
        }
    }
}
