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

public import SWBCore
import SWBLibc
import SWBUtil
import Foundation

#if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
private enum SwiftDriverPlanCacheMode: String {
    case off
    case record
    case replay
    case readWrite = "read-write"

    var canRead: Bool { self == .replay || self == .readWrite }
    var canWrite: Bool { self == .record || self == .readWrite }
}

package enum SwiftDriverPlanCacheKeyScope: String, Sendable {
    case legacy
    case driver

    package func actionKey(baseKey: String, driverIdentity: String) -> String {
        guard self == .driver else { return baseKey }
        let context = SHA256Context()
        for field in ["swift-driver-plan-cache-driver-key-v1", baseKey, driverIdentity] {
            let bytes = Array(field.utf8)
            context.add(number: UInt64(bytes.count))
            context.add(bytes: bytes)
        }
        return context.signature.asString
    }
}

package func swiftDriverPlanCacheScopeIdentity(
    moduleName: String, outputPrefix: String, variant: String,
    architecture: String, ruleInfo: [String], commandLine: [String]
) -> String {
    let context = SHA256Context()
    for field in [
        "swift-driver-plan-cache-scope-identity-v1",
        moduleName, outputPrefix, variant, architecture,
    ] + ruleInfo + commandLine {
        let bytes = Array(field.utf8)
        context.add(number: UInt64(bytes.count))
        context.add(bytes: bytes)
    }
    return context.signature.asString
}

package struct SwiftDriverPlanLiveCASReference: Codable, Sendable, Equatable {
    package static let currentSchema = "swift-driver-plan-live-cas-reference-v1"

    package let schema: String
    package let actionKey: String
    package let casPath: String

    package init(actionKey: String, casPath: String) {
        self.schema = Self.currentSchema
        self.actionKey = actionKey
        self.casPath = casPath
    }

    package func validate(actionKey: String, casPath: String) throws {
        guard schema == Self.currentSchema,
              self.actionKey == actionKey,
              self.casPath == casPath else {
            throw StubError.error("Live Swift Driver planning CAS identity changed.")
        }
    }
}

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
private struct SwiftDriverDependencyPlanObservationConfiguration {
    static let modeVariable = "SWIFT_BUILD_DRIVER_PLAN_COMPATIBILITY_MODE"
    static let manifestPathVariable = "SWIFT_BUILD_DRIVER_PLAN_DEPENDENCY_MANIFEST"
    static let planInputIdentityVariable = "SWIFT_BUILD_DRIVER_PLAN_INPUT_IDENTITY"

    let manifestPath: Path
    let planInputIdentity: String

    init?(environment: [String: String]) throws {
        guard let mode = environment[Self.modeVariable], mode != "off" else { return nil }
        guard mode == "observe" else {
            throw StubError.error("\(Self.modeVariable) must be off or observe.")
        }
        guard let rawManifestPath = environment[Self.manifestPathVariable],
              Path(rawManifestPath).isAbsolute else {
            throw StubError.error("\(Self.manifestPathVariable) must be an absolute path in observe mode.")
        }
        guard let planInputIdentity = environment[Self.planInputIdentityVariable],
              planInputIdentity.count == 64,
              planInputIdentity.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw StubError.error("\(Self.planInputIdentityVariable) must be a lowercase SHA-256 digest.")
        }
        self.manifestPath = Path(rawManifestPath)
        self.planInputIdentity = planInputIdentity
    }
}

private struct SwiftDriverDependencyPlanObservationRecord: Codable {
    static let schema = "swift-build-driver-plan-observation-record-v1"

    let schema: String
    let exactActionKey: String
    let binding: SwiftDependencyPlanBinding

    init(exactActionKey: String, binding: SwiftDependencyPlanBinding) {
        self.schema = Self.schema
        self.exactActionKey = exactActionKey
        self.binding = binding
    }
}
#endif

private struct SwiftDriverPlanCacheConfiguration {
    static let rootVariable = "SWIFT_BUILD_DRIVER_PLAN_CACHE_ROOT"
    static let modeVariable = "SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE"
    static let keyVariable = "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY"
    static let keyScopeVariable = "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY_SCOPE"
    static let liveCASVariable = "SWIFT_BUILD_DRIVER_PLAN_CACHE_LIVE_CAS"
    static let invalidateSourceVariable =
        "SWIFT_BUILD_DRIVER_PLAN_CACHE_INVALIDATE_SOURCE"

    let root: Path
    let mode: SwiftDriverPlanCacheMode
    var key: String
    let baseKey: String
    let keyScope: SwiftDriverPlanCacheKeyScope
    let useLiveCAS: Bool
    let invalidateSource: Path?
    #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
    let dependencyObservation: SwiftDriverDependencyPlanObservationConfiguration?
    #endif

    init?(environment: [String: String]) throws {
        guard let rawMode = environment[Self.modeVariable],
              let mode = SwiftDriverPlanCacheMode(rawValue: rawMode),
              mode != .off else {
            return nil
        }
        guard let rawRoot = environment[Self.rootVariable], !rawRoot.isEmpty else {
            throw StubError.error("\(Self.rootVariable) is required when Swift Driver plan caching is enabled.")
        }
        let root = Path(rawRoot)
        guard root.isAbsolute else {
            throw StubError.error("\(Self.rootVariable) must be absolute.")
        }
        guard let key = environment[Self.keyVariable],
              key.count == 64,
              key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw StubError.error("\(Self.keyVariable) must be a lowercase SHA-256 digest.")
        }
        guard let keyScope = SwiftDriverPlanCacheKeyScope(
            rawValue: environment[Self.keyScopeVariable] ?? "legacy"
        ) else {
            throw StubError.error("\(Self.keyScopeVariable) must be legacy or driver.")
        }
        let useLiveCAS: Bool
        switch environment[Self.liveCASVariable] ?? "0" {
        case "0": useLiveCAS = false
        case "1": useLiveCAS = true
        default:
            throw StubError.error("\(Self.liveCASVariable) must be 0 or 1.")
        }
        let invalidateSource: Path?
        if let rawSource = environment[Self.invalidateSourceVariable] {
            let source = Path(rawSource)
            guard source.isAbsolute else {
                throw StubError.error(
                    "\(Self.invalidateSourceVariable) must be absolute."
                )
            }
            invalidateSource = source
        } else {
            invalidateSource = nil
        }
        self.root = root
        self.mode = mode
        self.key = key
        self.baseKey = key
        self.keyScope = keyScope
        self.useLiveCAS = useLiveCAS
        self.invalidateSource = invalidateSource
        #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
        self.dependencyObservation = try SwiftDriverDependencyPlanObservationConfiguration(
            environment: environment
        )
        #endif
    }

    func scoped(to driverIdentity: String) -> Self {
        var scoped = self
        scoped.key = keyScope.actionKey(
            baseKey: baseKey, driverIdentity: driverIdentity
        )
        return scoped
    }

    var actionPath: Path {
        actionPath(for: key)
    }

    var casSnapshotPath: Path {
        casSnapshotPath(for: key)
    }

    var directPlanPath: Path {
        root.join("direct").join(String(key.prefix(2))).join("\(key).json")
    }

    var liveCASReferencePath: Path {
        root.join("live-cas").join(String(key.prefix(2))).join("\(key).json")
    }

    func actionPath(for actionKey: String) -> Path {
        root.join("actions").join(String(actionKey.prefix(2))).join("\(actionKey).msgpack")
    }

    func casSnapshotPath(for actionKey: String) -> Path {
        root.join("cas").join(String(actionKey.prefix(2))).join(actionKey)
    }

    #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
    func dependencyObservationPath(for lookupIdentity: String) -> Path {
        root.join("compatible").join(String(lookupIdentity.prefix(2))).join("\(lookupIdentity).json")
    }
    #endif

    func publishCASSnapshot(from source: Path) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.str) else {
            throw StubError.error("Swift Driver planning CAS is missing at \(source.str).")
        }
        if fileManager.fileExists(atPath: casSnapshotPath.str) {
            return
        }
        try fileManager.createDirectory(
            atPath: casSnapshotPath.dirname.str,
            withIntermediateDirectories: true
        )
        let temporary = casSnapshotPath.dirname.join(".\(key).tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(atPath: temporary.str) }
        try fileManager.copyItem(atPath: source.str, toPath: temporary.str)
        try fileManager.moveItem(atPath: temporary.str, toPath: casSnapshotPath.str)
    }

    func publishLiveCASReference(to source: Path) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.str) else {
            throw StubError.error("Live Swift Driver planning CAS is missing.")
        }
        let reference = SwiftDriverPlanLiveCASReference(
            actionKey: key, casPath: source.str
        )
        let encoded = try JSONEncoder().encode(reference)
        try fileManager.createDirectory(
            atPath: liveCASReferencePath.dirname.str,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: liveCASReferencePath.str) {
            let existing = try Data(contentsOf: URL(fileURLWithPath: liveCASReferencePath.str))
            guard existing == encoded else {
                throw StubError.error("Live Swift Driver planning CAS reference conflict.")
            }
            return
        }
        let temporary = liveCASReferencePath.dirname.join(
            ".\(key).tmp-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(atPath: temporary.str) }
        try encoded.write(
            to: URL(fileURLWithPath: temporary.str), options: .atomic
        )
        do {
            try fileManager.moveItem(
                atPath: temporary.str, toPath: liveCASReferencePath.str
            )
        } catch {
            if fileManager.fileExists(atPath: liveCASReferencePath.str),
               try Data(contentsOf: URL(fileURLWithPath: liveCASReferencePath.str))
                    == encoded {
                return
            }
            throw error
        }
    }

    func validateLiveCASReference(at source: Path) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.str),
              fileManager.fileExists(atPath: liveCASReferencePath.str) else {
            throw StubError.error("Live Swift Driver planning CAS is unavailable.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: liveCASReferencePath.str))
        let reference = try JSONDecoder().decode(
            SwiftDriverPlanLiveCASReference.self, from: data
        )
        try reference.validate(actionKey: key, casPath: source.str)
    }

    func restoreCASSnapshot(to destination: Path, actionKey: String? = nil) throws {
        let fileManager = FileManager.default
        let source = casSnapshotPath(for: actionKey ?? key)
        guard fileManager.fileExists(atPath: source.str) else {
            throw StubError.error("Cached Swift Driver planning CAS snapshot is missing.")
        }
        try fileManager.createDirectory(
            atPath: destination.dirname.str,
            withIntermediateDirectories: true
        )
        let temporary = destination.dirname.join(".plan-cache-restore-\(UUID().uuidString)")
        let backup = destination.dirname.join(".plan-cache-backup-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(atPath: temporary.str)
            try? fileManager.removeItem(atPath: backup.str)
        }
        try fileManager.copyItem(atPath: source.str, toPath: temporary.str)
        let hadDestination = fileManager.fileExists(atPath: destination.str)
        if hadDestination {
            try fileManager.moveItem(atPath: destination.str, toPath: backup.str)
        }
        do {
            try fileManager.moveItem(atPath: temporary.str, toPath: destination.str)
        } catch {
            if hadDestination, fileManager.fileExists(atPath: backup.str) {
                try? fileManager.moveItem(atPath: backup.str, toPath: destination.str)
            }
            throw error
        }
    }
}

private struct SwiftDriverDirectPlanManifest: Codable {
    static let schema = "swift-build-direct-swift-plan-v1"
    static let writeLock = NSLock()

    struct Job: Codable {
        let key: String
        let dependencies: [String]
        let ruleInfoType: String
        let moduleName: String
        let workingDirectory: String
        let commandLine: [String]
        let inputs: [String]
        let outputs: [String]
        let cacheKeys: [String]

        init(_ job: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob) {
            key = String(describing: job.key)
            dependencies = job.dependencies.map { String(describing: $0) }
            ruleInfoType = job.driverJob.ruleInfoType
            moduleName = job.driverJob.moduleName
            workingDirectory = job.workingDirectory.str
            commandLine = job.driverJob.commandLine.map(\.asString)
            inputs = job.driverJob.inputs.map(\.str)
            outputs = job.driverJob.outputs.map(\.str)
            cacheKeys = job.driverJob.cacheKeys
        }
    }

    let schema: String
    let actionKey: String
    let jobs: [Job]

    init(actionKey: String, snapshot: SwiftDriverPlanCacheSnapshot) {
        schema = Self.schema
        self.actionKey = actionKey
        jobs = snapshot.plannedBuild.plannedTargetJobs.map(Job.init)
    }

    init(actionKey: String, jobs: [Job]) {
        schema = Self.schema
        self.actionKey = actionKey
        self.jobs = jobs
    }

    func merging(_ other: Self) throws -> Self {
        guard actionKey == other.actionKey else {
            throw StubError.error("Swift Driver direct plan action identity differs.")
        }
        var seen = Set<String>()
        let merged = (jobs + other.jobs).filter { job in
            let identity = [
                job.moduleName, job.key, job.workingDirectory,
                job.commandLine.joined(separator: "\u{0}"),
            ].joined(separator: "\u{1f}")
            return seen.insert(identity).inserted
        }.sorted {
            ($0.moduleName, $0.key, $0.workingDirectory)
                < ($1.moduleName, $1.key, $1.workingDirectory)
        }
        return Self(actionKey: actionKey, jobs: merged)
    }
}

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
private func dependencyPlanJobs(
    from snapshot: SwiftDriverPlanCacheSnapshot
) -> [SwiftDependencyPlanBinding.Job] {
    let plannedJobs = snapshot.explicitModuleJobs + snapshot.plannedBuild.plannedTargetJobs
    let identitiesByKey = Dictionary(uniqueKeysWithValues: plannedJobs.map { job in
        let commandLine = job.driverJob.commandLine.map(\.asString)
        let primaryIndices = commandLine.indices.filter { index in
            commandLine[index] == "-primary-file" && commandLine.indices.contains(index + 1)
        }
        let primarySourceIdentity = primaryIndices.count == 1
            ? commandLine[primaryIndices[0] + 1]
            : nil
        var identityFields = [
            "swift-build-dependency-plan-job-v1",
            primarySourceIdentity ?? "",
            job.driverJob.ruleInfoType,
            job.driverJob.moduleName,
        ]
        identityFields.append(contentsOf: job.driverJob.outputs.map(\.str))
        let context = SHA256Context()
        for field in identityFields {
            let bytes = Array(field.utf8)
            context.add(number: UInt64(bytes.count))
            context.add(bytes: bytes)
        }
        return (String(describing: job.key), context.signature.asString)
    })
    return plannedJobs.map { job in
        let commandLine = job.driverJob.commandLine.map(\.asString)
        let primaryIndices = commandLine.indices.filter { index in
            commandLine[index] == "-primary-file" && commandLine.indices.contains(index + 1)
        }
        let primarySourceIdentity = primaryIndices.count == 1
            ? commandLine[primaryIndices[0] + 1]
            : nil
        return .init(
            identity: identitiesByKey[String(describing: job.key)]!,
            primarySourceIdentity: primarySourceIdentity,
            dependencies: job.dependencies.map {
                let key = String(describing: $0)
                return identitiesByKey[key] ?? "missing:\(key)"
            },
            commandShape: [job.driverJob.ruleInfoType, job.driverJob.moduleName],
            outputShape: job.driverJob.outputs.map(\.str)
        )
    }
}
#endif
#endif

final public class SwiftDriverTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        "swift-driver-invocation"
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        // A dynamically requested planning job should always execute
        return false
    }

    public override func taskSetup(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        for (index, input) in (task.executionInputs ?? []).enumerated() {
            dynamicExecutionDelegate.requestInputNode(node: input, nodeID: UInt(index))
        }
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        guard let payload = task.payload as? SwiftTaskPayload, let driverPayload = payload.driverPayload else {
            outputDelegate.emitError("Invalid payload for Swift integrated driver support")
            return .failed
        }

        let dependencyGraph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph

        guard let target = task.forTarget else {
            outputDelegate.emitError("Can't plan Swift driver invocation without a target.")
            return .failed
        }

        guard task.commandLine.starts(with: ["builtin-SwiftDriver", "--"]) else {
            outputDelegate.emitError("Unexpected command line prefix")
            return .failed
        }

        do {
            let environment: [String: String]
            if let executionEnvironment = executionDelegate.environment {
                environment = executionEnvironment.merging(task.environment.bindingsDictionary, uniquingKeysWith: { a, b in b })
            } else {
                environment = task.environment.bindingsDictionary
            }
            #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
            let experimentControlEnvironment = ProcessInfo.processInfo.environment.merging(
                environment,
                uniquingKeysWith: { _, taskValue in taskValue }
            )
            #endif

            let commandLine = task.commandLineAsStrings.split(separator: "--", maxSplits: 1, omittingEmptySubsequences: false)[1]
            var plannedFromCache = false
            var planBuildDiagnostics: [Diagnostic] = []
            #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
            let planCacheTimer = ElapsedTimer()
            var planCacheConfiguration: SwiftDriverPlanCacheConfiguration?
            var planCacheOutcome = "off"
            var planCacheReadDurationNS: UInt64 = 0
            var planCachePlanDurationNS: UInt64 = 0
            var planCacheWriteDurationNS: UInt64 = 0
            var planCacheBytes = 0
            var directPlanBytes = 0
            var planCacheInvalidatedJobCount = 0
            #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
            var dependencyObservationManifest: SwiftDependencyModuleManifest?
            var dependencyObservationOutcome = "off"
            var dependencyObservationLookupIdentity = "none"
            var dependencyObservationCandidateKey = "none"
            var dependencyObservationCandidateBinding: SwiftDependencyPlanBinding?
            var dependencyPreflightConfiguration: SwiftDependencyShadowConfiguration?
            #endif
            do {
                #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
                planCacheConfiguration = try SwiftDriverPlanCacheConfiguration(
                    environment: experimentControlEnvironment
                )
                #else
                planCacheConfiguration = try SwiftDriverPlanCacheConfiguration(environment: environment)
                #endif
            } catch {
                planCacheOutcome = "invalid_configuration"
                outputDelegate.note("SWIFT_DRIVER_PLAN_CACHE outcome=invalid_configuration fallback=apple error=\(error.localizedDescription)")
            }
            if let configuration = planCacheConfiguration {
                planCacheConfiguration = configuration.scoped(
                    to: swiftDriverPlanCacheScopeIdentity(
                        moduleName: driverPayload.moduleName,
                        outputPrefix: driverPayload.outputPrefix,
                        variant: driverPayload.variant,
                        architecture: driverPayload.architecture,
                        ruleInfo: driverPayload.ruleInfo,
                        commandLine: driverPayload.commandLine
                    )
                )
            }
            #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
            do {
                if let configurationPath = try SwiftDependencyShadowConfiguration.path(
                    environment: experimentControlEnvironment
                ) {
                    let bytes = try executionDelegate.fs.read(configurationPath)
                    let configuration = try JSONDecoder().decode(
                        SwiftDependencyShadowConfiguration.self,
                        from: Data(bytes.bytes)
                    )
                    if configuration.mode == .admit,
                       configuration.preflightManifestPath != nil {
                        dependencyPreflightConfiguration = configuration
                        let manifestBytes = try executionDelegate.fs.read(
                            Path(configuration.previousManifestPath)
                        )
                        dependencyObservationManifest = try JSONDecoder().decode(
                            SwiftDependencyModuleManifest.self,
                            from: Data(manifestBytes.bytes)
                        )
                        dependencyObservationOutcome = "preflight_ready"
                    }
                }
            } catch {
                dependencyObservationOutcome = "preflight_invalid_configuration"
                outputDelegate.note(
                    "SWIFT_DRIVER_PLAN_COMPATIBILITY outcome=preflight_invalid_configuration fallback=apple error=\(error.localizedDescription)"
                )
            }
            if let observation = planCacheConfiguration?.dependencyObservation {
                do {
                    let manifestBytes = try executionDelegate.fs.read(observation.manifestPath)
                    dependencyObservationManifest = try JSONDecoder().decode(
                        SwiftDependencyModuleManifest.self,
                        from: Data(manifestBytes.bytes)
                    )
                    dependencyObservationOutcome = "ready"
                } catch {
                    dependencyObservationOutcome = "invalid_manifest"
                    outputDelegate.note(
                        "SWIFT_DRIVER_PLAN_COMPATIBILITY outcome=invalid_manifest replay=disabled fallback=apple error=\(error.localizedDescription)"
                    )
                }
            }
            #endif
            if let planCacheConfiguration, planCacheConfiguration.mode.canRead {
                let readTimer = ElapsedTimer()
                if executionDelegate.fs.exists(planCacheConfiguration.actionPath) {
                    do {
                        guard let casOptions = driverPayload.casOptions else {
                            throw StubError.error("Swift Driver plan replay requires a compilation CAS.")
                        }
                        if planCacheConfiguration.useLiveCAS {
                            try planCacheConfiguration.validateLiveCASReference(
                                at: casOptions.casPath
                            )
                        } else {
                            try planCacheConfiguration.restoreCASSnapshot(
                                to: casOptions.casPath
                            )
                        }
                        let bytes = try executionDelegate.fs.read(planCacheConfiguration.actionPath)
                        planCacheBytes = bytes.count
                        var snapshot: SwiftDriverPlanCacheSnapshot = try MsgPackDeserializer.deserialize(bytes)
                        if let source = planCacheConfiguration.invalidateSource {
                            let invalidation = snapshot.invalidatingCompilationCacheKeys(
                                for: source
                            )
                            guard invalidation.invalidatedJobCount == 1 else {
                                throw StubError.error(
                                    "Cached plan expected exactly one changed source job, found \(invalidation.invalidatedJobCount)."
                                )
                            }
                            snapshot = invalidation.snapshot
                            planCacheInvalidatedJobCount = invalidation.invalidatedJobCount
                        }
                        try dependencyGraph.installCachedPlan(
                            key: driverPayload.uniqueID,
                            compilerLocation: driverPayload.compilerLocation,
                            target: target,
                            args: Array(commandLine),
                            workingDirectory: task.workingDirectory,
                            tempDirPath: driverPayload.tempDirPath,
                            explicitModulesTempDirPath: driverPayload.explicitModulesTempDirPath,
                            environment: environment,
                            eagerCompilationEnabled: driverPayload.eagerCompilationEnabled,
                            casOptions: driverPayload.casOptions,
                            snapshot: snapshot
                        )
                        plannedFromCache = true
                        planCacheOutcome = "hit"
                    } catch {
                        planCacheOutcome = "invalid"
                        outputDelegate.note("SWIFT_DRIVER_PLAN_CACHE outcome=invalid fallback=apple error=\(error.localizedDescription)")
                    }
                } else {
                    planCacheOutcome = "miss"
                    #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
                    if let preflightConfiguration = dependencyPreflightConfiguration,
                       let manifest = dependencyObservationManifest {
                        do {
                            guard let candidateKey = preflightConfiguration
                                    .compatiblePlanCandidateKey,
                                  let planInputIdentity = preflightConfiguration
                                    .compatiblePlanInputIdentity,
                                  candidateKey.count == 64,
                                  candidateKey.allSatisfy({
                                    $0.isHexDigit && !$0.isUppercase
                                  }),
                                  planInputIdentity.count == 64,
                                  planInputIdentity.allSatisfy({
                                    $0.isHexDigit && !$0.isUppercase
                                  }),
                                  executionDelegate.fs.exists(
                                    planCacheConfiguration.actionPath(for: candidateKey)
                                  ),
                                  executionDelegate.fs.exists(
                                    planCacheConfiguration.casSnapshotPath(for: candidateKey)
                                  ),
                                  let casOptions = driverPayload.casOptions else {
                                throw StubError.error(
                                    "Compatible Swift Driver preflight candidate is incomplete."
                                )
                            }
                            // A trusted local CompilationCAS retained from the
                            // candidate build is a strict superset of the
                            // planning-time snapshot: explicit module jobs add
                            // PCM/Swiftmodule objects after planning completes.
                            // Replacing it here would discard those objects and
                            // make the preflight frontend command unusable.
                            if !executionDelegate.fs.exists(casOptions.casPath) {
                                try planCacheConfiguration.restoreCASSnapshot(
                                    to: casOptions.casPath,
                                    actionKey: candidateKey
                                )
                            }
                            let bytes = try executionDelegate.fs.read(
                                planCacheConfiguration.actionPath(for: candidateKey)
                            )
                            let snapshot: SwiftDriverPlanCacheSnapshot = try
                                MsgPackDeserializer.deserialize(bytes)
                            let binding = try SwiftDependencyPlanBinding(
                                moduleManifest: manifest,
                                planInputIdentity: planInputIdentity,
                                jobs: dependencyPlanJobs(from: snapshot)
                            )
                            guard case .compatible = binding.observe(
                                currentManifest: manifest,
                                currentPlanInputIdentity: planInputIdentity
                            ) else {
                                throw StubError.error(
                                    "Compatible Swift Driver preflight topology failed validation."
                                )
                            }
                            let graphPreflight: SwiftDependencyCompatiblePlanPreflight.GraphResult?
                            let serialPreflight: SwiftDependencyCompatiblePlanPreflight.Result?
                            if preflightConfiguration.compatiblePlanPreflightMode
                                == .dependencyGraph {
                                graphPreflight = try SwiftDependencyCompatiblePlanPreflight
                                    .runGraphLive(
                                        snapshot: snapshot,
                                        configuration: preflightConfiguration,
                                        environment: environment,
                                        fs: executionDelegate.fs
                                    )
                                serialPreflight = nil
                            } else {
                                graphPreflight = nil
                                serialPreflight = try SwiftDependencyCompatiblePlanPreflight
                                    .runLive(
                                        snapshot: snapshot,
                                        configuration: preflightConfiguration,
                                        environment: environment,
                                        fs: executionDelegate.fs
                                    )
                            }
                            try dependencyGraph.installCachedPlan(
                                key: driverPayload.uniqueID,
                                compilerLocation: driverPayload.compilerLocation,
                                target: target,
                                args: Array(commandLine),
                                workingDirectory: task.workingDirectory,
                                tempDirPath: driverPayload.tempDirPath,
                                explicitModulesTempDirPath: driverPayload.explicitModulesTempDirPath,
                                environment: environment,
                                eagerCompilationEnabled: driverPayload.eagerCompilationEnabled,
                                casOptions: driverPayload.casOptions,
                                snapshot: snapshot
                            )
                            plannedFromCache = true
                            planCacheBytes = bytes.count
                            planCacheOutcome = "compatible_hit"
                            dependencyObservationLookupIdentity = binding.lookupIdentity
                            dependencyObservationCandidateKey = candidateKey
                            dependencyObservationCandidateBinding = binding
                            dependencyObservationOutcome = "compatible_preflight"
                            if let preflight = graphPreflight {
                                for event in preflight.projectionCacheEvents {
                                    outputDelegate.note(
                                        "SWIFT_DEPENDENCY_PROJECTION_CAS outcome=\(event.outcome) key=\(event.key) duration_ns=\(event.durationNS) bytes=\(event.bytes ?? 0)"
                                    )
                                }
                                outputDelegate.note(
                                    "SWIFT_DRIVER_PLAN_GRAPH_CLOSURE outcome=admitted affected=\(preflight.closure.invalidationCone.affectedSources.count) reusable=\(preflight.closure.invalidationCone.reusableSources.count) changed_keys=\(preflight.closure.changedProviderKeys.count) false_negative=unknown overadmitted=unknown projection_compiler_ns=\(preflight.compilerDurationNS)"
                                )
                                outputDelegate.note(
                                    "SWIFT_DRIVER_DEPENDENCY_ONLY_PROJECTION outcome=admitted executions=\(preflight.executions.count) compiler_ns=\(preflight.compilerDurationNS)"
                                )
                                outputDelegate.note(
                                    "SWIFT_DRIVER_PLAN_PREFLIGHT outcome=graph_admitted candidate_key=\(candidateKey) affected=\(preflight.closure.invalidationCone.affectedSources.count) reusable=\(preflight.closure.invalidationCone.reusableSources.count) compiled=0 dependency_only=\(preflight.executions.count) compiler_ns=\(preflight.compilerDurationNS)"
                                )
                            } else if let preflight = serialPreflight {
                                let preflightCompileDurationNS = preflight.executions.reduce(0) {
                                    $0 + $1.durationNS
                                }
                                let fixedPointAffected = Set(
                                    preflight.fixedPoint.invalidationCone.affectedSources
                                )
                                let graphAffected = Set(
                                    preflight.priorGraphClosure.invalidationCone.affectedSources
                                )
                                let falseNegativeCount = fixedPointAffected
                                    .subtracting(graphAffected).count
                                let overadmittedCount = graphAffected
                                    .subtracting(fixedPointAffected).count
                                outputDelegate.note(
                                    "SWIFT_DRIVER_PLAN_GRAPH_CLOSURE outcome=observed affected=\(graphAffected.count) reusable=\(preflight.priorGraphClosure.invalidationCone.reusableSources.count) changed_keys=\(preflight.priorGraphClosure.changedProviderKeys.count) false_negative=\(falseNegativeCount) overadmitted=\(overadmittedCount) projection_compiler_ns=\(preflight.changedProjectionDurationNS)"
                                )
                                if let comparison = preflight.dependencyOnlyProjectionComparison {
                                    outputDelegate.note(
                                        "SWIFT_DRIVER_DEPENDENCY_ONLY_PROJECTION outcome=observed parity=\(comparison.exact ? "exact" : "mismatch") closure_input_parity=\(comparison.closureRelevantExact ? "exact" : "mismatch") closure_parity=\(preflight.dependencyOnlyGraphClosureParity == true ? "exact" : "mismatch") executions=\(preflight.dependencyOnlyExecutions.count) compiler_ns=\(preflight.dependencyOnlyExecutions.reduce(0) { $0 + $1.durationNS }) compiler_equal=\(comparison.compilerVersion ? 1 : 0) fingerprint_equal=\(comparison.sourceFileInterfaceFingerprint ? 1 : 0) provided_equal=\(comparison.providedInterfaces ? 1 : 0) depended_equal=\(comparison.dependedInterfaces ? 1 : 0) dependency_only_provided=\(comparison.dependencyOnlyProvidedCount) full_provided=\(comparison.fullProvidedCount) dependency_only_depended=\(comparison.dependencyOnlyDependedCount) full_depended=\(comparison.fullDependedCount)"
                                    )
                                }
                                outputDelegate.note(
                                    "SWIFT_DRIVER_PLAN_PREFLIGHT outcome=admitted candidate_key=\(candidateKey) affected=\(preflight.fixedPoint.invalidationCone.affectedSources.count) reusable=\(preflight.fixedPoint.invalidationCone.reusableSources.count) compiled=\(preflight.executions.count) compiler_ns=\(preflightCompileDurationNS)"
                                )
                            }
                        } catch {
                            dependencyObservationOutcome = "preflight_failed"
                            outputDelegate.note(
                                "SWIFT_DRIVER_PLAN_PREFLIGHT outcome=failed fallback=apple error=\(error.localizedDescription)"
                            )
                        }
                    }
                    if !plannedFromCache,
                       let observation = planCacheConfiguration.dependencyObservation,
                       let manifest = dependencyObservationManifest {
                        do {
                            let lookupIdentity = try SwiftDependencyPlanBinding.lookupIdentity(
                                moduleManifest: manifest,
                                planInputIdentity: observation.planInputIdentity
                            )
                            dependencyObservationLookupIdentity = lookupIdentity
                            let observationPath = planCacheConfiguration.dependencyObservationPath(
                                for: lookupIdentity
                            )
                            guard executionDelegate.fs.exists(observationPath) else {
                                dependencyObservationOutcome = "miss"
                                throw StubError.error("No compatible Swift Driver plan observation exists.")
                            }
                            let recordBytes = try executionDelegate.fs.read(observationPath)
                            let record = try JSONDecoder().decode(
                                SwiftDriverDependencyPlanObservationRecord.self,
                                from: Data(recordBytes.bytes)
                            )
                            guard record.schema == SwiftDriverDependencyPlanObservationRecord.schema,
                                  record.exactActionKey.count == 64,
                                  record.exactActionKey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                                  executionDelegate.fs.exists(planCacheConfiguration.actionPath(for: record.exactActionKey)),
                                  executionDelegate.fs.exists(planCacheConfiguration.casSnapshotPath(for: record.exactActionKey)) else {
                                throw StubError.error("Compatible Swift Driver plan observation is incomplete.")
                            }
                            guard case .compatible = record.binding.observe(
                                currentManifest: manifest,
                                currentPlanInputIdentity: observation.planInputIdentity
                            ) else {
                                throw StubError.error("Compatible Swift Driver plan observation failed validation.")
                            }
                            dependencyObservationCandidateKey = record.exactActionKey
                            dependencyObservationCandidateBinding = record.binding
                            dependencyObservationOutcome = "compatible"
                        } catch {
                            if dependencyObservationOutcome != "miss" {
                                dependencyObservationOutcome = "invalid"
                            }
                        }
                    }
                    #endif
                }
                planCacheReadDurationNS = readTimer.elapsedTime().nanoseconds
            }
            #endif

            if !plannedFromCache {
                #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
                let planTimer = ElapsedTimer()
                #endif
                let planResult = dependencyGraph.planBuild(key: driverPayload.uniqueID,
                                                           compilerLocation: driverPayload.compilerLocation,
                                                           target: target,
                                                           args: Array(commandLine),
                                                           workingDirectory: task.workingDirectory,
                                                           tempDirPath: driverPayload.tempDirPath,
                                                           explicitModulesTempDirPath: driverPayload.explicitModulesTempDirPath,
                                                           environment: environment,
                                                           eagerCompilationEnabled: driverPayload.eagerCompilationEnabled,
                                                           casOptions: driverPayload.casOptions)
                #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
                planCachePlanDurationNS = planTimer.elapsedTime().nanoseconds
                #endif
                planBuildDiagnostics = planResult.diagnostics
                guard planResult.success else { return .failed }
            }

            // Read and emit any serialized diagnostics reported by the scanner. Then report any diagnostics from planBuild
            // which were not present in the serialized diagnostics. We match on the message and location only, because
            // the diagnostics returned by the API are lower-fidelity compared to those in the serialized diagnostics file.
            let serializedDiagnostics: [Diagnostic]
            if let scannerDiagnosticsPath = driverPayload.scannerDiagnosticsOutputPath {
                serializedDiagnostics = dynamicExecutionDelegate.operationContext.readSerializedDiagnostics(
                    at: scannerDiagnosticsPath,
                    workingDirectory: task.workingDirectory,
                    appendToOutputStream: true,
                    attachmentInfo: driverPayload.diagnosticAttachmentInfo,
                    fs: executionDelegate.fs
                )
            } else {
                serializedDiagnostics = []
            }
            struct SeenDiagnostic: Hashable {
                var message: String
                var location: Diagnostic.Location
            }
            var seenDiagnostics: Set<SeenDiagnostic> = []
            for serializedDiagnostic in serializedDiagnostics {
                outputDelegate.emit(serializedDiagnostic)
                seenDiagnostics.insert(.init(message: serializedDiagnostic.data.description, location: serializedDiagnostic.location))
            }
            for diagnostic in planBuildDiagnostics {
                // Diagnostics returned by planBuild may have rendered fix-its as part of the message, so only compare the first line.
                if seenDiagnostics.contains(.init(message: diagnostic.data.description.split("\n").0, location: diagnostic.location)) {
                    continue
                } else {
                    outputDelegate.emit(diagnostic)
                }
            }

            #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
            if !plannedFromCache, let planCacheConfiguration, planCacheConfiguration.mode.canWrite {
                let writeTimer = ElapsedTimer()
                do {
                    let snapshot = try await dependencyGraph.planCacheSnapshot(for: driverPayload.uniqueID)
                    let bytes = MsgPackSerializer.serialize(snapshot)
                    planCacheBytes = bytes.count
                    let directPlan = SwiftDriverDirectPlanManifest(
                        actionKey: planCacheConfiguration.key,
                        snapshot: snapshot
                    )
                    let directBytes = try SwiftDriverDirectPlanManifest.writeLock.withLock {
                        try executionDelegate.fs.createDirectory(
                            planCacheConfiguration.directPlanPath.dirname,
                            recursive: true
                        )
                        let mergedDirectPlan: SwiftDriverDirectPlanManifest
                        if executionDelegate.fs.exists(planCacheConfiguration.directPlanPath) {
                            let existingBytes = try executionDelegate.fs.read(
                                planCacheConfiguration.directPlanPath
                            )
                            let existing = try JSONDecoder().decode(
                                SwiftDriverDirectPlanManifest.self,
                                from: Data(existingBytes.bytes)
                            )
                            mergedDirectPlan = try existing.merging(directPlan)
                        } else {
                            mergedDirectPlan = directPlan
                        }
                        let encoded = try JSONEncoder().encode(mergedDirectPlan)
                        try executionDelegate.fs.write(
                            planCacheConfiguration.directPlanPath,
                            contents: ByteString(encoded),
                            atomically: true
                        )
                        return encoded
                    }
                    directPlanBytes = directBytes.count
                    guard let casOptions = driverPayload.casOptions else {
                        throw StubError.error("Swift Driver plan recording requires a compilation CAS.")
                    }
                    if planCacheConfiguration.useLiveCAS {
                        try planCacheConfiguration.publishLiveCASReference(
                            to: casOptions.casPath
                        )
                    } else {
                        try planCacheConfiguration.publishCASSnapshot(
                            from: casOptions.casPath
                        )
                    }
                    try executionDelegate.fs.createDirectory(planCacheConfiguration.actionPath.dirname, recursive: true)
                    if executionDelegate.fs.exists(planCacheConfiguration.actionPath) {
                        guard try executionDelegate.fs.read(planCacheConfiguration.actionPath) == bytes else {
                            throw StubError.error("Swift Driver plan cache action conflict for exact key.")
                        }
                    } else {
                        try executionDelegate.fs.write(planCacheConfiguration.actionPath, contents: bytes, atomically: true)
                    }
                    #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
                    if let observation = planCacheConfiguration.dependencyObservation,
                       let manifest = dependencyObservationManifest {
                        do {
                            let binding = try SwiftDependencyPlanBinding(
                                moduleManifest: manifest,
                                planInputIdentity: observation.planInputIdentity,
                                jobs: dependencyPlanJobs(from: snapshot)
                            )
                            let record = SwiftDriverDependencyPlanObservationRecord(
                                exactActionKey: planCacheConfiguration.key,
                                binding: binding
                            )
                            let observationBytes = try JSONEncoder().encode(record)
                            let observationPath = planCacheConfiguration.dependencyObservationPath(
                                for: binding.lookupIdentity
                            )
                            try executionDelegate.fs.createDirectory(observationPath.dirname, recursive: true)
                            try executionDelegate.fs.write(
                                observationPath,
                                contents: ByteString(observationBytes),
                                atomically: true
                            )
                            dependencyObservationLookupIdentity = binding.lookupIdentity
                            if let candidateBinding = dependencyObservationCandidateBinding {
                                dependencyObservationOutcome = candidateBinding.planStructureIdentity
                                    == binding.planStructureIdentity
                                    ? "compatible_confirmed_recorded"
                                    : "structure_mismatch_recorded"
                            } else {
                                dependencyObservationCandidateKey = planCacheConfiguration.key
                                dependencyObservationOutcome = dependencyObservationOutcome == "ready"
                                    ? "recorded"
                                    : "\(dependencyObservationOutcome)_recorded"
                            }
                        } catch {
                            dependencyObservationOutcome = "record_error"
                            outputDelegate.note(
                                "SWIFT_DRIVER_PLAN_COMPATIBILITY outcome=record_error replay=disabled fallback=apple error=\(error.localizedDescription)"
                            )
                        }
                    }
                    #endif
                    planCacheOutcome = "recorded"
                } catch {
                    planCacheOutcome = "record_error"
                    outputDelegate.note("SWIFT_DRIVER_PLAN_CACHE outcome=record_error fallback=planned error=\(error.localizedDescription)")
                }
                planCacheWriteDurationNS = writeTimer.elapsedTime().nanoseconds
            }
            if planCacheConfiguration != nil {
                outputDelegate.note(
                    "SWIFT_DRIVER_PLAN_CACHE outcome=\(planCacheOutcome) key=\(planCacheConfiguration?.key ?? "none") base_key=\(planCacheConfiguration?.baseKey ?? "none") key_scope=\(planCacheConfiguration?.keyScope.rawValue ?? "none") cas_mode=\(planCacheConfiguration?.useLiveCAS == true ? "live" : "snapshot") invalidated_jobs=\(planCacheInvalidatedJobCount) bytes=\(planCacheBytes) direct_plan_bytes=\(directPlanBytes) duration_ns=\(planCacheTimer.elapsedTime().nanoseconds) read_ns=\(planCacheReadDurationNS) apple_plan_ns=\(planCachePlanDurationNS) write_ns=\(planCacheWriteDurationNS)"
                )
                #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
                if planCacheConfiguration?.dependencyObservation != nil
                    || dependencyPreflightConfiguration != nil {
                    outputDelegate.note(
                        "SWIFT_DRIVER_PLAN_COMPATIBILITY outcome=\(dependencyObservationOutcome) lookup=\(dependencyObservationLookupIdentity) candidate_key=\(dependencyObservationCandidateKey) candidate_replay=\(dependencyObservationOutcome == "compatible_preflight" ? "enabled" : "disabled") planning=\(plannedFromCache ? "cache" : "apple")"
                    )
                }
                #endif
            }
            #endif
        }

        do {
            if executionDelegate.userPreferences.enableDebugActivityLogs {
                let plannedBuild = try dependencyGraph.queryPlannedBuild(for: driverPayload.uniqueID)

                let jobsDebugDescription: (ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob>) -> String = {
                    $0.map({ "\t\t\($0.debugDescription)" }).joined(separator: "\n")
                }

                let cohortArchsSuffix = driverPayload.cohortArchitectures.isEmpty ? "" : ", " + driverPayload.cohortArchitectures.joined(separator: ", ")
                var message = "Swift Driver planned jobs for target \(task.forTarget?.target.name ?? "<unknown>") (\(driverPayload.architecture)-\(driverPayload.variant)\(cohortArchsSuffix)):"
                if driverPayload.explicitModulesEnabled {
                    message += "\n\tExplicit Modules:\n" + jobsDebugDescription(plannedBuild.explicitModulesPlannedDriverJobs()[...])
                }
                message += "\n\tCompilation Requirements:\n" + jobsDebugDescription(plannedBuild.compilationRequirementsPlannedDriverJobs())
                message += "\n\tCompilation:\n" + jobsDebugDescription(plannedBuild.compilationPlannedDriverJobs())
                message += "\n\tAfter Compilation:\n" + jobsDebugDescription(plannedBuild.afterCompilationPlannedDriverJobs())
                message += "\n\tVerification:\n" + jobsDebugDescription(plannedBuild.verificationPlannedDriverJobs())

                outputDelegate.emitNote(message)
            }

            if driverPayload.reportRequiredTargetDependencies != .no && driverPayload.explicitModulesEnabled, let target = task.forTarget {
                let dependencyModuleNames = try await dependencyGraph.queryTransitiveDependencyModuleNames(for: driverPayload.uniqueID)
                for dependencyModuleName in dependencyModuleNames {
                    if let targetDependencies = dynamicExecutionDelegate.operationContext.definingTargetsByModuleName[dependencyModuleName] {
                        for targetDependency in targetDependencies {
                            guard targetDependency.guid != target.guid else {
                                continue
                            }
                            executionDelegate.taskDiscoveredRequiredTargetDependency(target: target, antecedent: targetDependency, reason: .swiftModuleDependency(dependentModuleName: driverPayload.moduleName, dependencyModuleName: dependencyModuleName), warningLevel: driverPayload.reportRequiredTargetDependencies)
                        }
                    }
                }
            }

            if let linkerResponseFilePath = driverPayload.linkerResponseFilePath {
                var responseFileCommandLine: [String] = []
                if driverPayload.explicitModulesEnabled {
                    for swiftmodulePath in try dependencyGraph.querySwiftmodulesNeedingRegistrationForDebugging(for: driverPayload.uniqueID) {
                        responseFileCommandLine.append(contentsOf: ["-Xlinker", "-add_ast_path", "-Xlinker", "\(swiftmodulePath)"])
                    }
                }
                let contents = ByteString(encodingAsUTF8: ResponseFiles.responseFileContents(args: responseFileCommandLine, format: driverPayload.linkerResponseFileFormat))
                try executionDelegate.fs.createDirectory(linkerResponseFilePath.dirname, recursive: true)
                try executionDelegate.fs.write(linkerResponseFilePath, contents: contents, atomically: true)
            }

            return .succeeded
        } catch {
            outputDelegate.error("Unexpected error in querying jobs from dependency graph: \(error)")
            return .failed
        }
    }
}
