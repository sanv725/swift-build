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

private struct SwiftDriverPlanCacheConfiguration {
    static let rootVariable = "SWIFT_BUILD_DRIVER_PLAN_CACHE_ROOT"
    static let modeVariable = "SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE"
    static let keyVariable = "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY"

    let root: Path
    let mode: SwiftDriverPlanCacheMode
    let key: String

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
        self.root = root
        self.mode = mode
        self.key = key
    }

    var actionPath: Path {
        root.join("actions").join(String(key.prefix(2))).join("\(key).msgpack")
    }

    var casSnapshotPath: Path {
        root.join("cas").join(String(key.prefix(2))).join(key)
    }

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

    func restoreCASSnapshot(to destination: Path) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: casSnapshotPath.str) else {
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
        try fileManager.copyItem(atPath: casSnapshotPath.str, toPath: temporary.str)
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
            do {
                planCacheConfiguration = try SwiftDriverPlanCacheConfiguration(environment: environment)
            } catch {
                planCacheOutcome = "invalid_configuration"
                outputDelegate.note("SWIFT_DRIVER_PLAN_CACHE outcome=invalid_configuration fallback=apple error=\(error.localizedDescription)")
            }
            if let planCacheConfiguration, planCacheConfiguration.mode.canRead {
                let readTimer = ElapsedTimer()
                if executionDelegate.fs.exists(planCacheConfiguration.actionPath) {
                    do {
                        guard let casOptions = driverPayload.casOptions else {
                            throw StubError.error("Swift Driver plan replay requires a compilation CAS.")
                        }
                        try planCacheConfiguration.restoreCASSnapshot(to: casOptions.casPath)
                        let bytes = try executionDelegate.fs.read(planCacheConfiguration.actionPath)
                        planCacheBytes = bytes.count
                        let snapshot: SwiftDriverPlanCacheSnapshot = try MsgPackDeserializer.deserialize(bytes)
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
                    guard let casOptions = driverPayload.casOptions else {
                        throw StubError.error("Swift Driver plan recording requires a compilation CAS.")
                    }
                    try planCacheConfiguration.publishCASSnapshot(from: casOptions.casPath)
                    try executionDelegate.fs.createDirectory(planCacheConfiguration.actionPath.dirname, recursive: true)
                    if executionDelegate.fs.exists(planCacheConfiguration.actionPath) {
                        guard try executionDelegate.fs.read(planCacheConfiguration.actionPath) == bytes else {
                            throw StubError.error("Swift Driver plan cache action conflict for exact key.")
                        }
                    } else {
                        try executionDelegate.fs.write(planCacheConfiguration.actionPath, contents: bytes, atomically: true)
                    }
                    planCacheOutcome = "recorded"
                } catch {
                    planCacheOutcome = "record_error"
                    outputDelegate.note("SWIFT_DRIVER_PLAN_CACHE outcome=record_error fallback=planned error=\(error.localizedDescription)")
                }
                planCacheWriteDurationNS = writeTimer.elapsedTime().nanoseconds
            }
            if planCacheConfiguration != nil {
                outputDelegate.note(
                    "SWIFT_DRIVER_PLAN_CACHE outcome=\(planCacheOutcome) key=\(planCacheConfiguration?.key ?? "none") bytes=\(planCacheBytes) duration_ns=\(planCacheTimer.elapsedTime().nanoseconds) read_ns=\(planCacheReadDurationNS) apple_plan_ns=\(planCachePlanDurationNS) write_ns=\(planCacheWriteDurationNS)"
                )
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
