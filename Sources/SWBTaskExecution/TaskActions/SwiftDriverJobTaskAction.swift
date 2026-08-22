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

public import SWBCore
public import SWBUtil
public import SWBLLBuild
import SWBProtocol

#if canImport(Darwin)
package typealias SwiftCacheOutputAccessPlan = DescriptorRelativeFileOperations.OutputAccessPlan
#else
package struct SwiftCacheOutputAccessPlan: Sendable {}
#endif

#if SWIFT_BUILD_ACCELERATOR_FAULT_INJECTION
#if canImport(System)
import System
#else
import SystemPackage
#endif
import Synchronization
#endif

package struct SwiftCacheCachedOutput: Sendable, Equatable {
    package let kindName: String
    package let isMaterialized: Bool

    package init(kindName: String, isMaterialized: Bool) {
        self.kindName = kindName
        self.isMaterialized = isMaterialized
    }
}

package struct SwiftCacheReplayStreams: Sendable, Equatable {
    package let standardOutput: String
    package let standardError: String

    package init(standardOutput: String, standardError: String) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// The narrow adapter used by accelerator observe/verify. It keeps opaque
/// Swift Driver CAS wrapper types out of state-machine tests.
package protocol SwiftCacheOperations {
    associatedtype Compilation
    associatedtype ReplayInstance

    func queryLocalCacheKey(_ key: String) throws -> Compilation?
    func cachedOutputs(for compilation: Compilation) throws -> [SwiftCacheCachedOutput]
    func createReplayInstance(commandLine: [String]) throws -> ReplayInstance
    func replayCompilation(_ compilation: Compilation, using instance: ReplayInstance) throws -> SwiftCacheReplayStreams
}

package struct SwiftCASCacheOperations: SwiftCacheOperations {
    package let databases: SwiftCASDatabases

    package init(databases: SwiftCASDatabases) {
        self.databases = databases
    }

    package func queryLocalCacheKey(_ key: String) throws -> SwiftCachedCompilation? {
        try databases.queryLocalCacheKey(key)
    }

    package func cachedOutputs(for compilation: SwiftCachedCompilation) throws -> [SwiftCacheCachedOutput] {
        try compilation.getOutputs().map {
            SwiftCacheCachedOutput(kindName: $0.kindName, isMaterialized: $0.isMaterialized)
        }
    }

    package func createReplayInstance(commandLine: [String]) throws -> SwiftCacheReplayInstance {
        try databases.createReplayInstance(cmd: commandLine)
    }

    package func replayCompilation(_ compilation: SwiftCachedCompilation, using instance: SwiftCacheReplayInstance) throws -> SwiftCacheReplayStreams {
        let result = try databases.replayCompilation(instance: instance, compilation: compilation)
        return try SwiftCacheReplayStreams(standardOutput: result.getStdOut(), standardError: result.getStdErr())
    }
}

package enum SwiftCacheProbeMissReason: Sendable, Equatable {
    case missingKey
    case nonMaterializedOutput
    case unsupportedOutput
}

package enum SwiftCacheProbeResult<Compilation> {
    case hit(compilations: [Compilation], outputCount: Int)
    case miss(SwiftCacheProbeMissReason)
}

package struct SwiftCacheOutputManifest: Sendable, Equatable {
    package enum FileKind: String, Sendable, Equatable {
        case regularFile
    }

    package struct Entry: Sendable, Equatable {
        package let ordinal: Int
        package let fileKind: FileKind
        package let permissions: UInt16
        package let byteCount: Int64
        package let digest: ByteString

        package init(ordinal: Int, fileKind: FileKind, permissions: UInt16, byteCount: Int64, digest: ByteString) {
            self.ordinal = ordinal
            self.fileKind = fileKind
            self.permissions = permissions
            self.byteCount = byteCount
            self.digest = digest
        }
    }

    package let entries: [Entry]

    package var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.byteCount }
    }

    package init(entries: [Entry]) {
        self.entries = entries
    }

    package func mismatchCount(comparedTo other: Self) -> Int {
        let sharedMismatchCount = zip(entries, other.entries).reduce(into: 0) {
            if $1.0 != $1.1 { $0 += 1 }
        }
        return sharedMismatchCount + abs(entries.count - other.entries.count)
    }
}

package enum SwiftCacheOutputError: Error, Sendable, Equatable {
    case missingOutput
    case unsupportedOutput
    case scrubFailed
}

package enum SwiftAcceleratorCachePreparationOutcome: Sendable, Equatable {
    case unavailable
    case unauthorizedTrust
    case quarantined
    case unsupportedOutput
    case cancelled
    case miss
    case wouldHit
    case verificationReady
    case unsafeTrustHit
    case queryError
    case replayError
    case manifestError
    case scrubFailure

    package var shouldExecuteFrontend: Bool {
        self != .scrubFailure && self != .cancelled && self != .unsafeTrustHit
    }
}

/// A nonserialized capability required by direct internal `.trust` preparation.
/// Normal builds expose no constructor. Dedicated canary builds may mint one
/// only from the exact private environment contract below.
package struct SwiftAcceleratorCacheTrustAuthorization: Sendable {
    package static let environmentVariable = "SWIFTBUILD_INTERNAL_ACCELERATOR_CACHE_TRUST"

    private init() {}

    #if SWIFT_BUILD_ACCELERATOR_TRUST_CANARY
    package static func parse(environment: [String: String]) -> Self? {
        guard environment[environmentVariable] == "v1" else {
            return nil
        }
        return Self()
    }
    #endif

    package static func removeControlVariable(from environment: inout [String: String]) {
        environment.removeValue(forKey: environmentVariable)
    }
}

/// A nonserialized test seam for exercising the accelerator's existing
/// fail-open decision boundaries. The environment-controlled adapter is only
/// compiled into dedicated fault-injection service builds below.
package enum SwiftAcceleratorCacheInjectedFault: String, Sendable, Equatable {
    case queryError = "query_error"
    case replayError = "replay_error"
    case manifestError = "manifest_error"
}

/// A nonserialized test seam for cooperative cancellation at real cache
/// boundaries. Environment selection is compiled only into the dedicated
/// fault-injection service below.
package enum SwiftAcceleratorCacheCancellationCheckpoint: String, Sendable, Equatable {
    case queryStage = "query_stage"
    case replayStage = "replay_stage"
    case postMaterialization = "post_materialization"
}

private enum SwiftAcceleratorCacheInjectedError: Error {
    case injected
}

#if SWIFT_BUILD_ACCELERATOR_FAULT_INJECTION
package struct SwiftAcceleratorCacheFaultInjectionConfiguration: Sendable, Equatable {
    package struct Request: Sendable, Equatable {
        package let fault: SwiftAcceleratorCacheInjectedFault
        package let selector: String
    }

    package static let faultEnvironmentVariable = "SWIFTBUILD_INTERNAL_ACCELERATOR_CACHE_FAULT"
    package static let discoveryEnvironmentVariable = "SWIFTBUILD_INTERNAL_ACCELERATOR_CACHE_FAULT_DISCOVERY"

    package let request: Request?
    package let discoveryEnabled: Bool

    package init(environment: [String: String]) {
        discoveryEnabled = environment[Self.discoveryEnvironmentVariable] == "1"
        guard let rawRequest = environment[Self.faultEnvironmentVariable] else {
            request = nil
            return
        }
        let fields = rawRequest.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == "v1",
              let fault = SwiftAcceleratorCacheInjectedFault(rawValue: String(fields[1])),
              Self.isLowercaseSHA256(String(fields[2])) else {
            request = nil
            return
        }
        request = .init(fault: fault, selector: String(fields[2]))
    }

    package static func removeControlVariables(from environment: inout [String: String]) {
        environment.removeValue(forKey: faultEnvironmentVariable)
        environment.removeValue(forKey: discoveryEnvironmentVariable)
    }

    package static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }
}

package final class SwiftAcceleratorCacheFaultInjectionController: @unchecked Sendable {
    package static let shared = SwiftAcceleratorCacheFaultInjectionController(
        configuration: .init(environment: ProcessInfo.processInfo.environment)
    )

    package let configuration: SwiftAcceleratorCacheFaultInjectionConfiguration
    private let claimed = SWBMutex(false)

    package init(configuration: SwiftAcceleratorCacheFaultInjectionConfiguration) {
        self.configuration = configuration
    }

    package func claim(
        selector: String,
        mode: SwiftBuildAcceleratorCacheMode,
        eligibility: SwiftBuildAcceleratorCacheEligibility,
        checkpoint: SwiftAcceleratorCacheInjectedFault
    ) -> Bool {
        guard mode == .verify,
              eligibility == .eligible,
              let request = configuration.request,
              request.fault == checkpoint,
              request.selector == selector else {
            return false
        }
        return claimed.withLock { claimed in
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

package struct SwiftAcceleratorCacheCancellationConfiguration: Sendable, Equatable {
    package struct Request: Sendable, Equatable {
        package let checkpoint: SwiftAcceleratorCacheCancellationCheckpoint
        package let selector: String
        package let readyDirectory: Path
    }

    package static let environmentVariable = "SWIFTBUILD_INTERNAL_ACCELERATOR_CACHE_CANCEL"
    package static let readyDirectoryEnvironmentVariable = "SWIFTBUILD_INTERNAL_ACCELERATOR_CACHE_CANCEL_READY_DIRECTORY"

    package let request: Request?

    package init(environment: [String: String]) {
        guard let rawRequest = environment[Self.environmentVariable],
              let rawReadyDirectory = environment[Self.readyDirectoryEnvironmentVariable] else {
            request = nil
            return
        }
        let fields = rawRequest.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == "v1",
              let checkpoint = SwiftAcceleratorCacheCancellationCheckpoint(rawValue: String(fields[1])),
              SwiftAcceleratorCacheFaultInjectionConfiguration.isLowercaseSHA256(String(fields[2])),
              Path(rawReadyDirectory).isAbsolute else {
            request = nil
            return
        }
        request = .init(checkpoint: checkpoint, selector: String(fields[2]), readyDirectory: Path(rawReadyDirectory))
    }

    package static func removeControlVariables(from environment: inout [String: String]) {
        environment.removeValue(forKey: environmentVariable)
        environment.removeValue(forKey: readyDirectoryEnvironmentVariable)
    }
}

package enum SwiftAcceleratorCacheCancellationReadyMarker {
    package static func path(
        directory: Path,
        checkpoint: SwiftAcceleratorCacheCancellationCheckpoint,
        selector: String
    ) -> Path {
        directory.join("cache-cancel-ready-v1-\(checkpoint.rawValue)-\(selector).marker")
    }

    package static func contents(
        checkpoint: SwiftAcceleratorCacheCancellationCheckpoint,
        selector: String
    ) -> ByteString {
        ByteString(encodingAsUTF8: "schema\tswift-build-cache-cancel-ready-v1\ncheckpoint\t\(checkpoint.rawValue)\nselector\t\(selector)\n")
    }

    @discardableResult
    package static func publish(
        directory: Path,
        checkpoint: SwiftAcceleratorCacheCancellationCheckpoint,
        selector: String,
        fs: any FSProxy
    ) throws -> Path {
        guard directory.isAbsolute,
              SwiftAcceleratorCacheFaultInjectionConfiguration.isLowercaseSHA256(selector),
              fs.isDirectory(directory),
              !fs.isSymlink(directory) else {
            throw StubError.error("invalid Swift accelerator cache cancellation ready directory")
        }

        let markerPath = path(directory: directory, checkpoint: checkpoint, selector: selector)
        let markerContents = contents(checkpoint: checkpoint, selector: selector)
        let descriptor = try FileDescriptor.open(
            FilePath(markerPath.str),
            .writeOnly,
            options: [.create, .exclusiveCreate, .closeOnExec],
            permissions: [.ownerReadWrite]
        )
        do {
            try descriptor.writeAll(Data(markerContents.bytes))
            try descriptor.close()
        } catch {
            try? descriptor.close()
            throw error
        }

        try fs.setFilePermissions(markerPath, permissions: 0o600)
        guard !fs.isSymlink(markerPath),
              try fs.isFile(markerPath),
              try fs.getFilePermissions(markerPath) == 0o600,
              try fs.read(markerPath) == markerContents else {
            throw StubError.error("invalid Swift accelerator cache cancellation ready marker")
        }
        return markerPath
    }
}

package final class SwiftAcceleratorCacheCancellationController: @unchecked Sendable {
    package static let shared = SwiftAcceleratorCacheCancellationController(
        configuration: .init(environment: ProcessInfo.processInfo.environment)
    )

    package let configuration: SwiftAcceleratorCacheCancellationConfiguration
    private let claimed = SWBMutex(false)

    package init(configuration: SwiftAcceleratorCacheCancellationConfiguration) {
        self.configuration = configuration
    }

    package func claim(
        selector: String,
        mode: SwiftBuildAcceleratorCacheMode,
        eligibility: SwiftBuildAcceleratorCacheEligibility,
        checkpoint: SwiftAcceleratorCacheCancellationCheckpoint
    ) -> Bool {
        guard mode == .verify,
              eligibility == .eligible,
              let request = configuration.request,
              request.checkpoint == checkpoint,
              request.selector == selector else {
            return false
        }
        return claimed.withLock { claimed in
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
#endif

package struct SwiftAcceleratorCachePreparation: Sendable, Equatable {
    package let outcome: SwiftAcceleratorCachePreparationOutcome
    package let lookupDurationNS: UInt64
    package let replayDurationNS: UInt64?
    package let manifestDurationNS: UInt64?
    package let scrubDurationNS: UInt64?
    package let scrubSucceeded: Bool?
    package let cachedOutputCount: Int?
    package let shadowManifest: SwiftCacheOutputManifest?
    package let replayStreams: [SwiftCacheReplayStreams]?

    package init(
        outcome: SwiftAcceleratorCachePreparationOutcome,
        lookupDurationNS: UInt64,
        replayDurationNS: UInt64? = nil,
        manifestDurationNS: UInt64? = nil,
        scrubDurationNS: UInt64? = nil,
        scrubSucceeded: Bool? = nil,
        cachedOutputCount: Int? = nil,
        shadowManifest: SwiftCacheOutputManifest? = nil,
        replayStreams: [SwiftCacheReplayStreams]? = nil
    ) {
        self.outcome = outcome
        self.lookupDurationNS = lookupDurationNS
        self.replayDurationNS = replayDurationNS
        self.manifestDurationNS = manifestDurationNS
        self.scrubDurationNS = scrubDurationNS
        self.scrubSucceeded = scrubSucceeded
        self.cachedOutputCount = cachedOutputCount
        self.shadowManifest = shadowManifest
        self.replayStreams = replayStreams
    }
}

package struct SwiftAcceleratorCacheComparison: Sendable, Equatable {
    package let freshManifest: SwiftCacheOutputManifest?
    package let mismatchCount: Int
    package let comparedBytes: UInt64
    package let durationNS: UInt64

    package var isMatch: Bool {
        freshManifest != nil && mismatchCount == 0
    }
}

private enum AcceleratorCacheControlFlow: Error {
    case fallback
}

private struct SwiftAcceleratorCacheQuarantinedError: Error {}

private extension TaskCacheObservation.ExclusionReason {
    init(_ reason: SwiftBuildAcceleratorCacheExclusionReason) {
        switch reason {
        case .unsupportedXcode: self = .unsupportedXcode
        case .unsupportedHostArchitecture: self = .unsupportedHostArchitecture
        case .unsupportedConfiguration: self = .unsupportedConfiguration
        case .unsupportedPlatform: self = .unsupportedPlatform
        case .unsupportedArchitecture: self = .unsupportedArchitecture
        case .unsupportedAction: self = .unsupportedAction
        case .unsupportedCompilationMode: self = .unsupportedCompilationMode
        case .wholeModuleOptimization: self = .wholeModuleOptimization
        case .indexing: self = .indexing
        case .previews: self = .previews
        case .mixedLanguageSources: self = .mixedLanguageSources
        case .bridgingHeader: self = .bridgingHeader
        case .customBuildRule: self = .customBuildRule
        case .runScript: self = .runScript
        case .macroPlugin: self = .macroPlugin
        case .integratedDriverDisabled: self = .integratedDriverDisabled
        case .explicitModulesDisabled: self = .explicitModulesDisabled
        case .toolchainUnsupported: self = .toolchainUnsupported
        case .cachePluginEnabled: self = .cachePluginEnabled
        case .remoteCacheEnabled: self = .remoteCacheEnabled
        case .cacheUnavailable: self = .cacheUnavailable
        case .emptyCacheKeys: self = .emptyCacheKeys
        case .missingOutputs: self = .missingOutputs
        case .unsupportedOutput: self = .unsupportedOutput
        }
    }
}

public final class SwiftDriverJobTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        "swift-driver-job-execution"
    }

    private struct Options {
        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate) {
            outputDelegate.emitOutput { stream in
                stream <<< "usage: \(name) -- <swift_frontend_args>\n"
            }
        }

        let commandLine: [String]

        init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate) {
            var parsedCommandLine = [String]()

            var hadErrors = false

            func error(_ message: String) {
                outputDelegate.emitError(message)
                hadErrors = true
            }

            // Parse the arguments.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"

            var foundCommandLine = false

            while let arg = generator.next() {
                if foundCommandLine {
                    parsedCommandLine.append(arg)
                    continue
                }

                switch arg {
                case "--":
                    foundCommandLine = true
                    continue
                default:
                    error("unexpected argument: \(arg)")
                    break
                }
            }

            if parsedCommandLine.isEmpty {
                error("No commandline for Swift driver job given.")
            }

            if !hadErrors {
                self.commandLine = parsedCommandLine
            } else {
                // If there were errors, emit the usage and return an error.
                outputDelegate.emitOutput("\n")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }
        }
    }

    public enum SwiftDriverJobIdentifier: Serializable {
        case explicitDependency
        case targetCompile(_ identifier: String)

        public func serialize<T>(to serializer: T) where T : Serializer {
            serializer.beginAggregate(2)
            switch self {
                case .explicitDependency:
                    serializer.serialize(0)
                    serializer.serializeNil()
                case .targetCompile(let identifier):
                    serializer.serialize(1)
                    serializer.serialize(identifier)
            }
            serializer.endAggregate()
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            let code: Int = try deserializer.deserialize()
            switch code {
                case 0:
                    guard deserializer.deserializeNil() else { throw DeserializerError.deserializationFailed("Unexpected associated value for SwiftDriverJobIdentifier.") }
                    self = .explicitDependency
                case 1:
                    let string: String = try deserializer.deserialize()
                    self = .targetCompile(string)
                default:
                    throw DeserializerError.incorrectType("Unexpected type code for SwiftDriverJobIdentifier: \(code)")
            }
        }
    }

    let identifier: SwiftDriverJobIdentifier
    let variant: String?
    let arch: String
    let driverJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob
    let isUsingWholeModuleOptimization: Bool

    init(_ driverJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob, variant: String?, arch: String, identifier: SwiftDriverJobIdentifier, isUsingWholeModuleOptimization: Bool) {
        self.driverJob = driverJob
        self.variant = variant
        self.arch = arch
        self.identifier = identifier
        self.isUsingWholeModuleOptimization = isUsingWholeModuleOptimization
        super.init()
    }

    public override func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(6) {
            serializer.serialize(driverJob)
            serializer.serialize(variant)
            serializer.serialize(arch)
            serializer.serialize(identifier)
            serializer.serialize(isUsingWholeModuleOptimization)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(6)
        self.driverJob = try deserializer.deserialize()
        self.variant = try deserializer.deserialize()
        self.arch = try deserializer.deserialize()
        self.identifier = try deserializer.deserialize()
        self.isUsingWholeModuleOptimization = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    private struct State {
        var openDependencies: Set<UInt> = []
        var inputNodesRequested = false
        var cacheJobRequested = false
        var jobTaskIDBase: UInt = 0

        var executionError: String? = nil
        var jobDependencyFailed = false

        mutating func reset() {
            self = State()
        }
    }

    private var state = State()

    public override func getSignature(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate) -> ByteString {
        let md5 = InsecureHashContext()
        // We intentionally do not integrate the superclass signature here, because the driver job's signature captures the same information without requiring expensive serialization.
        md5.add(bytes: driverJob.signature)
        task.environment.computeSignature(into: md5)
        return md5.signature
    }

    private func requestCacheJobIfNecessary(_ task: any ExecutableTask, _ dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) throws {
        guard state.cacheJobRequested == false else { return }
        guard let payload = task.payload as? SwiftDriverJobDynamicTaskPayload else {
            fatalError("Unexpected payload type: \(type(of: task.payload)).")
        }
        let taskID = state.jobTaskIDBase
        if try Self.maybeRequestCachingKeyMaterialization(plannedJob: driverJob,
                                                          dynamicExecutionDelegate: dynamicExecutionDelegate,
                                                          casOptions: payload.casOptions,
                                                          compilerLocation: payload.compilerLocation,
                                                          taskID: taskID) {
            state.openDependencies.insert(taskID)
        }
        state.cacheJobRequested = true
    }

    private func requestInputNodesIfNecessary(_ task: any ExecutableTask, _ dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        guard state.inputNodesRequested == false else { return }
        if state.openDependencies.isEmpty {
            for (index, input) in (task.executionInputs ?? []).enumerated() {
                // rdar://82078120 pch input has wrong name, will fail build with missingInput
                if Path(input.identifier).fileExtension == "pch" { continue }
                dynamicExecutionDelegate.requestInputNode(node: input, nodeID: state.jobTaskIDBase + 1 + UInt(index))
            }
            state.inputNodesRequested = true
        }
    }

    internal func constructDriverJobTaskKey(variant: String?,
                                            arch: String,
                                            plannedJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob,
                                            identifier: String?,
                                            compilerLocation: LibSwiftDriver.CompilerLocation,
                                            casOptions: CASOptions?,
                                            acceleratorCachePolicy: SwiftBuildAcceleratorCachePolicy) -> DynamicTaskKey {
        let key: DynamicTaskKey
        if plannedJob.driverJob.categorizer.isExplicitDependencyBuild {
            key = .swiftDriverExplicitDependencyJob(SwiftDriverExplicitDependencyJobTaskKey(
                arch: arch,
                driverJobKey: plannedJob.key,
                driverJobSignature: plannedJob.signature,
                compilerLocation: compilerLocation,
                casOptions: casOptions,
                acceleratorCachePolicy: acceleratorCachePolicy))
        } else {
            guard let variant else {
                fatalError("Expected variant for non-explicit-module job: \(plannedJob.driverJob.descriptionForLifecycle)")
            }
            guard let jobID = identifier else {
                fatalError("Expected job identifier for target compile: \(plannedJob.driverJob.descriptionForLifecycle)")
            }
            key = .swiftDriverJob(SwiftDriverJobTaskKey(
                identifier: jobID,
                variant: variant,
                arch: arch,
                driverJobKey: plannedJob.key,
                driverJobSignature: plannedJob.signature,
                isUsingWholeModuleOptimization: isUsingWholeModuleOptimization,
                compilerLocation: compilerLocation,
                casOptions: casOptions,
                acceleratorCachePolicy: acceleratorCachePolicy))
        }
        return key
    }

    public override func taskSetup(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        state.reset()

        guard let payload = task.payload as? SwiftDriverJobDynamicTaskPayload else {
            fatalError("Unexpected payload type: \(type(of: task.payload)).")
        }

        do {
            let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
            let jobDependencies: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob]
            var jobID: String? = nil
            switch self.identifier {
                case .targetCompile(let identifierStr):
                    let plannedBuild = try graph.queryPlannedBuild(for: identifierStr)
                    jobDependencies = plannedBuild.dependencies(for: driverJob)
                    jobID = identifierStr
                case .explicitDependency:
                    guard let explicitBuildJob = graph.plannedExplicitDependencyBuildJob(for: self.driverJob.key) else {
                        state.executionError = "Could not query build containing explicit dependency build job: \(self.driverJob.driverJob.descriptionForLifecycle)"
                        return
                    }
                    jobDependencies = graph.explicitDependencies(for: explicitBuildJob)
            }

            let jobTaskIDBase = UInt((task.executionInputs ?? []).count)
            // For each depended-upon job, request a dynamic task.
            for (index, dependency) in jobDependencies.enumerated() {
                let isExplicitDependencyBuildJob = dependency.driverJob.categorizer.isExplicitDependencyBuild
                let taskKey = constructDriverJobTaskKey(variant: variant,
                                                        arch: arch,
                                                        plannedJob: dependency,
                                                        identifier: jobID,
                                                        compilerLocation: payload.compilerLocation,
                                                        casOptions: payload.casOptions,
                                                        acceleratorCachePolicy: payload.acceleratorCachePolicy)
                let taskID = jobTaskIDBase + UInt(index)
                state.openDependencies.insert(taskID)
                dynamicExecutionDelegate.requestDynamicTask(
                    toolIdentifier: SwiftDriverJobTaskAction.toolIdentifier,
                    taskKey: taskKey,
                    taskID: taskID,
                    singleUse: true,
                    workingDirectory: dependency.workingDirectory,
                    environment: task.environment,
                    forTarget: isExplicitDependencyBuildJob ? nil : task.forTarget,
                    priority: dependency.driverJob.categorizer.priority,
                    showEnvironment: task.showEnvironment,
                    reason: .wasScheduledBySwiftDriver
                )
            }
            state.jobTaskIDBase = jobTaskIDBase + UInt(jobDependencies.count)
            try requestCacheJobIfNecessary(task, dynamicExecutionDelegate)
            requestInputNodesIfNecessary(task, dynamicExecutionDelegate)
        } catch {
            state.executionError = error.localizedDescription
        }
    }

    private func isError(_ dependencyID: UInt, buildValueKind: BuildValueKind?, task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) -> Bool {
        guard let buildValueKind else {
            return true
        }

        guard buildValueKind.isFailed else {
            return false
        }

        do {
            let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
            let jobDependencies: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob]
            switch self.identifier {
                case .targetCompile(let identifier):
                    let plannedBuild = try graph.queryPlannedBuild(for: identifier)
                    jobDependencies = plannedBuild.dependencies(for: driverJob)
                case .explicitDependency:
                    jobDependencies = graph.explicitDependencies(for: driverJob)
            }

            let dependencyIdentifier = Int(dependencyID)
            if jobDependencies.indices.contains(dependencyIdentifier) {
                state.jobDependencyFailed = true
            } else {
                state.executionError = "Input \(driverJob.driverJob.inputs[safe: dependencyIdentifier - jobDependencies.count]?.str ?? "<unknown>") missing."
            }
        } catch {
            state.executionError = error.localizedDescription
        }
        return true
    }

    public override func taskDependencyReady(_ task: any ExecutableTask, _ dependencyID: UInt, _ buildValueKind: BuildValueKind?, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate) {
        state.openDependencies.remove(dependencyID)

        if isError(dependencyID, buildValueKind: buildValueKind, task: task, dynamicExecutionDelegate: dynamicExecutionDelegate) && !dynamicExecutionDelegate.continueBuildingAfterErrors {
            // Unless we want to continue building after errors, clear open dependencies to minimize cascading failures.
            state.openDependencies.removeAll()
            return
        }

        requestInputNodesIfNecessary(task, dynamicExecutionDelegate)
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        // A dynamically planned driver job should always execute
        return false
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {

        var plannedBuild: LibSwiftDriver.PlannedBuild?
        // Explicit dependency build jobs do not update the delegate's (driver's)
        // state (incl. incremental), so we do not require access to their planned build.
        switch self.identifier {
            case .targetCompile(let identifier):
                do {
                    let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
                    plannedBuild = try graph.queryPlannedBuild(for: identifier)
                } catch {
                    state.executionError = "Unable to get planned build for identifier \(identifier): \(error.localizedDescription)"
                }
            case .explicitDependency:
                break
        }

        defer {
            state.reset()
        }

        if let error = state.executionError {
            outputDelegate.emitError(error)
            return .failed
        }

        if state.jobDependencyFailed {
            return .cancelled
        }

        guard let options = Options(task.commandLineAsStrings, outputDelegate) else {
            return .failed
        }

        func emitCommandLine() {
            let commandString = defaultCommandSequenceEncoder(hostOS: executionDelegate.hostOperatingSystem).encode(options.commandLine)

            // <rdar://59354519> We need to find a way to use the generic infrastructure for displaying the command line in
            // the build log.
            outputDelegate.emitOutput(ByteString(encodingAsUTF8: commandString) + "\n")
        }

        if executionDelegate.userPreferences.enableDebugActivityLogs || executionDelegate.emitFrontendCommandLines {
            emitCommandLine()
        }

        var environment: [String: String]
        // FIXME: clean up environment for caching build.
        if let executionEnvironment = executionDelegate.environment {
            environment = executionEnvironment.merging(task.environment.bindingsDictionary, uniquingKeysWith: { a, b in b })

            // FIXME: rdar://134664046 (Add an EnvironmentBlock type to represent environment variables)
            #if os(Windows)
            if let value = environment.removeValue(forKey: "PATH") {
                environment["Path"] = value
            }
            #endif
        } else {
            environment = task.environment.bindingsDictionary
        }

        #if SWIFT_BUILD_ACCELERATOR_TRUST_CANARY
        let acceleratorTrustAuthorization = SwiftAcceleratorCacheTrustAuthorization.parse(environment: environment)
        #else
        let acceleratorTrustAuthorization: SwiftAcceleratorCacheTrustAuthorization? = nil
        #endif
        SwiftAcceleratorCacheTrustAuthorization.removeControlVariable(from: &environment)

        #if SWIFT_BUILD_ACCELERATOR_FAULT_INJECTION
        let acceleratorFaultController = SwiftAcceleratorCacheFaultInjectionController.shared
        let acceleratorCancellationController = SwiftAcceleratorCacheCancellationController.shared
        SwiftAcceleratorCacheFaultInjectionConfiguration.removeControlVariables(from: &environment)
        SwiftAcceleratorCacheCancellationConfiguration.removeControlVariables(from: &environment)
        let acceleratorFaultSelector = Self.acceleratorFaultSelector(
            targetIdentity: task.forTarget?.guid.stringValue,
            arch: arch,
            variant: variant,
            jobKey: driverJob.key
        )
        var acceleratorFaultCandidateWasProbed = false
        #endif

        guard let payload = task.payload as? SwiftDriverJobDynamicTaskPayload else {
            fatalError("Unexpected payload type: \(type(of: task.payload)).")
        }

        do {
            class OutputCapturingDelegate: ProcessDelegate {
                let plannedBuild: LibSwiftDriver.PlannedBuild?
                let driverJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob
                let arguments: [String]
                let environment: [String : String]
                let outputDelegate: any TaskOutputDelegate

                private(set) var output: ByteString = ""
                private var pid = llbuild_pid_t.invalid

                var executionError: String?
                var wasSignaled: Bool = false
                private var processStarted = false
                private var _commandResult: CommandResult?
                var commandResult: CommandResult? {
                    guard processStarted else {
                        return .cancelled
                    }
                    return _commandResult
                }

                init(plannedBuild: LibSwiftDriver.PlannedBuild?, driverJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob, arguments: [String], environment: [String : String], outputDelegate: any TaskOutputDelegate) {
                    self.plannedBuild = plannedBuild
                    self.driverJob = driverJob
                    self.arguments = arguments
                    self.environment = environment
                    self.outputDelegate = outputDelegate
                }

                func processStarted(pid: llbuild_pid_t?) {
                    processStarted = true
                    do {
                        guard let pid else {
                            // `pid` is only optional because the Windows implementation of llbuild's pid_t type is optional. This should never be nil on other platforms
                            throw StubError.error("Got no process identifier from spawning subprocess for \(self.driverJob.description).")
                        }
                        self.pid = pid
                        try plannedBuild?.jobStarted(job: driverJob, arguments: arguments, pid: pid.pid)
                    } catch {
                        executionError = error.localizedDescription
                    }
                }

                func processHadError(error: String) {
                    executionError = error
                }

                func processHadOutput(output: [UInt8]) {
                    let bytes = ByteString(output)
                    self.output += bytes
                    outputDelegate.emitOutput(bytes)
                }

                // Kept for compatibility with older versions of llbuild. Remove once rdar://97019909 is widely available.
                func processHadOutput(output: String) {
                    let bytes = ByteString(encodingAsUTF8: output)
                    self.output += bytes
                    outputDelegate.emitOutput(bytes)
                }

                func processFinished(result: CommandExtendedResult) {
                    if wasSignaled {
                        // If the process was already signaled, this might be in a reproducer creation. No need to update finish status.
                        return
                    }
                    guard let status = Processes.ExitStatus.init(rawValue: result.exitStatus) else {
                        // nil means the job is stopped or continued. It should not call finished.
                        return
                    }
                    wasSignaled = status.wasSignaled
                    // This may be updated by commandStarted in the case of certain failures,
                    // so only update the exit status in output delegate if it is nil.
                    if outputDelegate.result == nil {
                        outputDelegate.updateResult(TaskResult(result))
                    }
                    self._commandResult = result.result
                    do {
                        try plannedBuild?.jobFinished(job: driverJob, arguments: arguments, pid: pid.pid, environment: environment, exitStatus: status, output: output)
                    } catch {
                        executionError = error.localizedDescription
                    }
                }
            }

            // rdar://70881411 track dynamic jobs' outputs in llbuild
            for output in self.driverJob.driverJob.outputs {
                try? executionDelegate.fs.createDirectory(output.dirname, recursive: true)
            }

            let delegate = OutputCapturingDelegate(plannedBuild: plannedBuild, driverJob: driverJob, arguments: options.commandLine, environment: environment, outputDelegate: outputDelegate)

            let acceleratorPolicy = payload.acceleratorCachePolicy
            let cacheKeys = driverJob.driverJob.cacheKeys
            let plannedOutputs = driverJob.driverJob.outputs
            let observationMode: TaskCacheObservation.Mode = switch acceleratorPolicy.mode {
            case .stock: .stock
            case .observe: .observe
            case .verify: .verify
            case .trust: .trust
            }
            var observationEligibility: TaskCacheObservation.Eligibility = acceleratorPolicy.eligibility == .eligible ? .eligible : .ineligible
            var observationExclusionReason: TaskCacheObservation.ExclusionReason?
            if case .excluded(let reason) = acceleratorPolicy.eligibility {
                observationExclusionReason = .init(reason)
            }
            var observationOutcome: TaskCacheObservation.Outcome = observationExclusionReason == nil ? .miss : .excluded
            var observationFallback: TaskCacheObservation.FallbackReason?
            var lookupDurationNS: UInt64?
            var materializationDurationNS: UInt64?
            var verificationDurationNS: UInt64?
            var scrubDurationNS: UInt64?
            var compilerDurationNS: UInt64?
            var scrubOutcome: TaskCacheObservation.ScrubOutcome = .notRun
            var observedOutputCount: Int?
            var observedOutputBytes: UInt64?
            var mismatchCount: Int?
            var comparedBytes: UInt64?
            var finalDisposition: TaskCacheObservation.FinalDisposition = .executed
            var shadowManifest: SwiftCacheOutputManifest?
            var outputAccessPlan: SwiftCacheOutputAccessPlan?
            #if canImport(Darwin)
            var outputLeafExpectation: SwiftCacheOutputAccessPlan.LeafExpectation = .admitted
            #endif
            let isCancellationRequested = {
                _Concurrency.Task<Never, Never>.isCancelled
                    || (executionDelegate as? any TaskExecutionCancellationDelegate)?.isCancellationRequested == true
            }

            defer {
                if acceleratorPolicy.mode.isAcceleratorEnabled {
                    outputDelegate.recordCacheObservation(.init(
                        cacheKeys: cacheKeys,
                        mode: observationMode,
                        eligibility: observationEligibility,
                        exclusionReason: observationExclusionReason,
                        outcome: observationOutcome,
                        lookupDurationNS: lookupDurationNS,
                        materializationDurationNS: materializationDurationNS,
                        verificationDurationNS: verificationDurationNS,
                        scrubDurationNS: scrubDurationNS,
                        compilerDurationNS: compilerDurationNS,
                        scrubOutcome: scrubOutcome,
                        outputCount: observedOutputCount,
                        outputBytes: observedOutputBytes,
                        mismatchCount: mismatchCount,
                        comparedBytes: comparedBytes,
                        fallbackReason: observationFallback,
                        finalDisposition: finalDisposition
                    ))
                }
                #if SWIFT_BUILD_ACCELERATOR_FAULT_INJECTION
                if acceleratorFaultController.configuration.discoveryEnabled,
                   acceleratorFaultCandidateWasProbed {
                    outputDelegate.note(
                        "Swift accelerator cache fault candidate selector=\(acceleratorFaultSelector) outcome=\(observationOutcome.rawValue) key_count=\(cacheKeys.count) planned_output_count=\(plannedOutputs.count)"
                    )
                }
                #endif
            }

            var cas: SwiftCASDatabases?
            if Self.usesStockCacheReplayPath(mode: acceleratorPolicy.mode) {
                // Keep the upstream cache creation, pruning, replay, counters, and
                // diagnostics path unchanged when the accelerator is disabled.
                if let casOpts = payload.casOptions {
                    let swiftModuleDependencyGraph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
                    cas = try swiftModuleDependencyGraph.getCASDatabases(casOptions: casOpts, compilerLocation: payload.compilerLocation)

                    let casKey = ClangCachingPruneDataTaskKey(
                        path: payload.compilerLocation.compilerOrLibraryPath,
                        casOptions: casOpts
                    )
                    dynamicExecutionDelegate.operationContext.compilationCachingDataPruner.pruneCAS(
                        cas!,
                        key: casKey,
                        activityReporter: dynamicExecutionDelegate,
                        fileSystem: executionDelegate.fs
                    )
                } else {
                    cas = nil
                }

                if let db = cas,
                   let casOpts = payload.casOptions,
                   try await Self.replayCachedCommand(cas: db,
                                                      plannedJob: driverJob,
                                                      commandLine: options.commandLine,
                                                      dynamicExecutionDelegate: dynamicExecutionDelegate,
                                                      outputDelegate: outputDelegate,
                                                      casOptions: casOpts,
                                                      reportCacheKeys: executionDelegate.enableTaskCacheKeyReporting) {
                        return .succeeded
                }
            } else if !acceleratorPolicy.shouldProbe {
                observationEligibility = .ineligible
                observationOutcome = .excluded
            } else if acceleratorPolicy.mode.usesAcceleratorMaterialization,
                      Self.hasSharedObjectiveCHeaderOutput(commandLine: options.commandLine, plannedOutputs: plannedOutputs) {
                observationEligibility = .ineligible
                observationExclusionReason = .unsupportedOutput
                observationOutcome = .excluded
            } else if cacheKeys.isEmpty {
                observationEligibility = .ineligible
                observationExclusionReason = .emptyCacheKeys
                observationOutcome = .excluded
            } else if plannedOutputs.isEmpty {
                observationEligibility = .ineligible
                observationExclusionReason = .missingOutputs
                observationOutcome = .excluded
            } else {
                do {
                    try Self.validateOutputDestinations(plannedOutputs, fs: executionDelegate.fs)
                } catch {
                    observationEligibility = .ineligible
                    observationExclusionReason = .unsupportedOutput
                    observationOutcome = .excluded
                }

                if observationEligibility == .eligible, acceleratorPolicy.mode.usesAcceleratorMaterialization {
                    do {
                        switch try makeLocalFileSystemOutputAccessPlan(
                            paths: plannedOutputs,
                            fs: executionDelegate.fs,
                            isCancelled: isCancellationRequested
                        ) {
                        #if canImport(Darwin)
                        case .descriptor(let plan):
                            outputAccessPlan = plan
                        #endif
                        case .compatibilityFallback:
                            break
                        case .unsupportedFileSystem:
                            observationEligibility = .ineligible
                            observationExclusionReason = .unsupportedOutput
                            observationOutcome = .excluded
                        }
                    } catch is CancellationError {
                        observationOutcome = .cancelled
                        return .cancelled
                    } catch {
                        observationEligibility = .ineligible
                        observationExclusionReason = .unsupportedOutput
                        observationOutcome = .excluded
                    }
                }

                if observationEligibility == .eligible {
                    do {
                        guard let casOpts = payload.casOptions else {
                            observationOutcome = .unavailable
                            observationFallback = .noCAS
                            throw AcceleratorCacheControlFlow.fallback
                        }
                        let swiftModuleDependencyGraph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
                        guard let database = try swiftModuleDependencyGraph.getCASDatabases(casOptions: casOpts, compilerLocation: payload.compilerLocation) else {
                            observationOutcome = .unavailable
                            observationFallback = .noCAS
                            if casOpts.enableStrictCASErrors {
                                throw StubError.error("Swift accelerator cache is unavailable under strict CAS policy")
                            }
                            throw AcceleratorCacheControlFlow.fallback
                        }
                        cas = database

                        let casKey = ClangCachingPruneDataTaskKey(
                            path: payload.compilerLocation.compilerOrLibraryPath,
                            casOptions: casOpts
                        )
                        dynamicExecutionDelegate.operationContext.compilationCachingDataPruner.pruneCAS(
                            database,
                            key: casKey,
                            activityReporter: dynamicExecutionDelegate,
                            fileSystem: executionDelegate.fs
                        )

                        #if SWIFT_BUILD_ACCELERATOR_FAULT_INJECTION
                        acceleratorFaultCandidateWasProbed = true
                        let claimInjectedFault: ((SwiftAcceleratorCacheInjectedFault) -> Bool)? = { checkpoint in
                            acceleratorFaultController.claim(
                                selector: acceleratorFaultSelector,
                                mode: acceleratorPolicy.mode,
                                eligibility: acceleratorPolicy.eligibility,
                                checkpoint: checkpoint
                            )
                        }
                        let pauseAtCancellationCheckpoint: ((SwiftAcceleratorCacheCancellationCheckpoint) throws -> Void)? = { checkpoint in
                            guard acceleratorCancellationController.claim(
                                selector: acceleratorFaultSelector,
                                mode: acceleratorPolicy.mode,
                                eligibility: acceleratorPolicy.eligibility,
                                checkpoint: checkpoint
                            ) else {
                                return
                            }

                            guard let request = acceleratorCancellationController.configuration.request else {
                                throw SwiftAcceleratorCacheInjectedError.injected
                            }
                            do {
                                try SwiftAcceleratorCacheCancellationReadyMarker.publish(
                                    directory: request.readyDirectory,
                                    checkpoint: checkpoint,
                                    selector: acceleratorFaultSelector,
                                    fs: executionDelegate.fs
                                )
                            } catch {
                                outputDelegate.emitOutput(
                                    ByteString(encodingAsUTF8: "Swift accelerator cache cancellation ready marker failed checkpoint=\(checkpoint.rawValue) selector=\(acceleratorFaultSelector)\n")
                                )
                                throw SwiftAcceleratorCacheInjectedError.injected
                            }

                            outputDelegate.emitOutput(
                                ByteString(encodingAsUTF8: "Swift accelerator cache cancellation ready checkpoint=\(checkpoint.rawValue) selector=\(acceleratorFaultSelector)\n")
                            )
                            let deadline = Date().addingTimeInterval(120)
                            while !isCancellationRequested(), Date() < deadline {
                                Thread.sleep(forTimeInterval: 0.005)
                            }
                            guard isCancellationRequested() else {
                                outputDelegate.emitOutput(
                                    ByteString(encodingAsUTF8: "Swift accelerator cache cancellation hold timeout checkpoint=\(checkpoint.rawValue) selector=\(acceleratorFaultSelector)\n")
                                )
                                throw SwiftAcceleratorCacheInjectedError.injected
                            }
                            outputDelegate.emitOutput(
                                ByteString(encodingAsUTF8: "Swift accelerator cache cancellation observed checkpoint=\(checkpoint.rawValue) selector=\(acceleratorFaultSelector)\n")
                            )
                            throw CancellationError()
                        }
                        #else
                        let claimInjectedFault: ((SwiftAcceleratorCacheInjectedFault) -> Bool)? = nil
                        let pauseAtCancellationCheckpoint: ((SwiftAcceleratorCacheCancellationCheckpoint) throws -> Void)? = nil
                        #endif

                        let preparation = Self.prepareAcceleratorCache(
                            mode: acceleratorPolicy.mode,
                            trustAuthorization: acceleratorTrustAuthorization,
                            operations: SwiftCASCacheOperations(databases: database),
                            cacheKeys: cacheKeys,
                            expectedOutputKindGroups: driverJob.driverJob.cacheOutputKindGroups,
                            plannedOutputs: plannedOutputs,
                            commandLine: options.commandLine,
                            fs: executionDelegate.fs,
                            outputAccessPlan: outputAccessPlan,
                            claimInjectedFault: claimInjectedFault,
                            pauseAtCancellationCheckpoint: pauseAtCancellationCheckpoint,
                            isCancelled: isCancellationRequested,
                            isQuarantined: {
                                dynamicExecutionDelegate.operationContext.isAcceleratorCacheQuarantined
                            },
                            quarantineCache: {
                                dynamicExecutionDelegate.operationContext.quarantineAcceleratorCache()
                            }
                        )
                        lookupDurationNS = preparation.lookupDurationNS
                        materializationDurationNS = preparation.replayDurationNS
                        verificationDurationNS = preparation.manifestDurationNS
                        scrubDurationNS = preparation.scrubDurationNS
                        observedOutputCount = preparation.shadowManifest?.entries.count ?? preparation.cachedOutputCount
                        if let totalBytes = preparation.shadowManifest?.totalBytes {
                            observedOutputBytes = UInt64(totalBytes)
                        }
                        if let scrubSucceeded = preparation.scrubSucceeded {
                            scrubOutcome = scrubSucceeded ? .succeeded : .failed
                            #if canImport(Darwin)
                            if scrubSucceeded, outputAccessPlan != nil {
                                outputLeafExpectation = .absent
                            }
                            #endif
                        }

                        switch preparation.outcome {
                        case .unavailable:
                            observationOutcome = .unavailable
                            observationFallback = .noCAS
                        case .unauthorizedTrust:
                            observationOutcome = .unavailable
                            observationFallback = .unauthorizedTrust
                        case .quarantined:
                            observationOutcome = .unavailable
                            observationFallback = .buildQuarantined
                        case .unsupportedOutput:
                            observationEligibility = .ineligible
                            observationExclusionReason = .unsupportedOutput
                            observationOutcome = .excluded
                        case .cancelled:
                            observationOutcome = .cancelled
                        case .miss:
                            observationOutcome = .miss
                        case .wouldHit:
                            observationOutcome = .wouldHit
                        case .verificationReady:
                            observationOutcome = .wouldHit
                            shadowManifest = preparation.shadowManifest
                        case .unsafeTrustHit:
                            observationOutcome = .unsafeTrustHit
                        case .queryError:
                            observationOutcome = .cacheError
                            observationFallback = .queryError
                        case .replayError:
                            observationOutcome = .cacheError
                            observationFallback = .replayError
                        case .manifestError:
                            observationOutcome = .cacheError
                            observationFallback = .manifestError
                        case .scrubFailure:
                            observationOutcome = .cacheError
                            observationFallback = .scrubFailure
                        }

                        // Preparation raises the latch at the exact failure
                        // site. Keep this idempotent caller-side publication as
                        // defense in depth if a future failure path is added.
                        switch preparation.outcome {
                        case .replayError, .manifestError, .scrubFailure:
                            dynamicExecutionDelegate.operationContext.quarantineAcceleratorCache()
                        case .unavailable, .unauthorizedTrust, .quarantined, .unsupportedOutput, .cancelled, .miss, .wouldHit, .verificationReady, .unsafeTrustHit, .queryError:
                            break
                        }

                        if Self.shouldAcceptUnsafeTrustHit(
                            mode: acceleratorPolicy.mode,
                            outcome: preparation.outcome
                        ) {
                            finalDisposition = .cacheReplayed
                            outputDelegate.note("EXPERIMENTAL: accepted an unsafe Swift accelerator cache hit; skipped swift-frontend")
                            for streams in preparation.replayStreams ?? [] {
                                outputDelegate.emitOutput(ByteString(encodingAsUTF8: streams.standardOutput))
                                outputDelegate.emitOutput(ByteString(encodingAsUTF8: streams.standardError))
                            }
                            outputDelegate.incrementCounter(.swiftCacheHits)
                            outputDelegate.incrementTaskCounter(.cacheHits)
                            return .succeeded
                        }

                        if Self.cachePreparationIsFatal(preparation.outcome, strictCASErrors: casOpts.enableStrictCASErrors) {
                            if preparation.outcome == .scrubFailure {
                                outputDelegate.error("Swift accelerator cache replay outputs could not be scrubbed safely")
                            } else {
                                outputDelegate.error("Swift accelerator cache operation failed under strict CAS policy")
                            }
                            return .failed
                        }
                        if preparation.outcome == .cancelled {
                            return .cancelled
                        }
                    } catch AcceleratorCacheControlFlow.fallback {
                        // Cache-only failures are deliberately handled by the fresh
                        // compiler execution below.
                    } catch {
                        observationOutcome = .unavailable
                        observationFallback = .noCAS
                        if payload.casOptions?.enableStrictCASErrors == true {
                            throw error
                        }
                    }
                }
            }

            // Accelerator modes promise that the fresh frontend is authoritative.
            // Honor cancellation at the final boundary after any shadow outputs
            // have been scrubbed, without changing the upstream stock path.
            if Self.shouldCancelBeforeFrontend(
                mode: acceleratorPolicy.mode,
                isCancelled: isCancellationRequested()
            ) {
                observationOutcome = .cancelled
                return .cancelled
            }

            #if canImport(Darwin)
            if let outputAccessPlan {
                do {
                    try outputAccessPlan.revalidateCurrentNamespace(
                        leafExpectation: outputLeafExpectation,
                        isCancelled: isCancellationRequested
                    )
                } catch is CancellationError {
                    observationOutcome = .cancelled
                    return .cancelled
                } catch {
                    dynamicExecutionDelegate.operationContext.quarantineAcceleratorCache()
                    observationOutcome = .cacheError
                    observationFallback = .scrubFailure
                    scrubOutcome = .failed
                    outputDelegate.error("Swift accelerator cache output namespace changed before frontend execution")
                    return .failed
                }
            }
            #endif

            let compilerTimer = ElapsedTimer()
            do {
                try await spawn(commandLine: options.commandLine, environment: environment, workingDirectory: task.workingDirectory, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: delegate)
                compilerDurationNS = compilerTimer.elapsedTime().nanoseconds
            } catch {
                compilerDurationNS = compilerTimer.elapsedTime().nanoseconds
                throw error
            }

            if delegate.commandResult == .succeeded, let shadowManifest {
                finalDisposition = .verifiedThenExecuted
                let comparison: SwiftAcceleratorCacheComparison
                do {
                    #if canImport(Darwin)
                    if let outputAccessPlan {
                        comparison = try Self.compareFreshOutputs(
                            shadowManifest: shadowManifest,
                            outputAccessPlan: outputAccessPlan,
                            isCancelled: isCancellationRequested
                        )
                    } else {
                        comparison = Self.compareFreshOutputs(
                            shadowManifest: shadowManifest,
                            plannedOutputs: plannedOutputs,
                            fs: executionDelegate.fs
                        )
                    }
                    #else
                    comparison = Self.compareFreshOutputs(
                        shadowManifest: shadowManifest,
                        plannedOutputs: plannedOutputs,
                        fs: executionDelegate.fs
                    )
                    #endif
                } catch is CancellationError {
                    observationOutcome = .cancelled
                    return .cancelled
                } catch {
                    dynamicExecutionDelegate.operationContext.quarantineAcceleratorCache()
                    observationOutcome = .cacheError
                    observationFallback = .scrubFailure
                    scrubOutcome = .failed
                    outputDelegate.error("Swift accelerator cache output namespace changed before fresh comparison")
                    return .failed
                }
                verificationDurationNS = (verificationDurationNS ?? 0) + comparison.durationNS
                mismatchCount = comparison.mismatchCount
                comparedBytes = comparison.comparedBytes
                if let freshManifest = comparison.freshManifest {
                    observedOutputCount = freshManifest.entries.count
                    observedOutputBytes = UInt64(freshManifest.totalBytes)
                }
                if comparison.isMatch {
                    observationOutcome = .verifyMatch
                } else {
                    dynamicExecutionDelegate.operationContext.quarantineAcceleratorCache()
                    observationOutcome = .verifyMismatch
                    observationFallback = comparison.freshManifest == nil ? .manifestError : .mismatch
                    outputDelegate.warning("Swift accelerator cache verification found \(comparison.mismatchCount) output mismatch(es); fresh compiler outputs were retained")
                }
            } else if delegate.commandResult == .cancelled {
                observationOutcome = .cancelled
            }

            // Generate crash reproducoer.
            if delegate.wasSignaled {
                // The output directory for crash reproducer is:
                // * Specified by environment
                // * Primary output path directory
                // * Temp directory
                let reproDir = environment["SWIFT_CRASH_DIAGNOSTICS_DIR"].map(Path.init) ?? driverJob.driverJob.outputs.first?.dirname
                try await withTemporaryDirectory(dir: reproDir, prefix: "swift-crash-reproducer", removeTreeOnDeinit: false) { dir in
                    if let reproCommand = try await plannedBuild?.getCrashReproducerCommand(for: driverJob, output: dir) {
                        try await spawn(commandLine: reproCommand, environment: environment, workingDirectory: task.workingDirectory, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: delegate)
                        outputDelegate.note("Crash reproducer created in \(dir.str)")
                    }
                }
            }

            if let error = delegate.executionError {
                outputDelegate.error(error)
                return .failed
            }
            // If has remote cache, start uploading task.
            if let db = cas, let casOpts = payload.casOptions, casOpts.hasRemoteCache, delegate.commandResult == .succeeded {
                // upload only if succeed
                try Self.upload(cas: db,
                                plannedJob: driverJob,
                                dynamicExecutionDelegate: dynamicExecutionDelegate,
                                outputDelegate: outputDelegate,
                                enableDiagnosticRemarks: casOpts.enableDiagnosticRemarks,
                                enableStrictCASErrors: casOpts.enableStrictCASErrors)
            }

            if delegate.commandResult == .failed && !executionDelegate.userPreferences.enableDebugActivityLogs && !executionDelegate.emitFrontendCommandLines {
                outputDelegate.emitOutput("Failed frontend command:\n")
                emitCommandLine()
            }

            return delegate.commandResult ?? .failed
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }
    }

    /// Intended to be called during task dependency setup.
    /// If remote caching is enabled it will request a `SwiftCachingMaterializeKeyTaskAction`
    /// as task dependency.
    static func maybeRequestCachingKeyMaterialization(
        plannedJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        casOptions: CASOptions?,
        compilerLocation: LibSwiftDriver.CompilerLocation,
        taskID: UInt
    ) throws -> Bool {
        guard let casOptions, casOptions.hasRemoteCache else {
            return false
        }
        let cacheQueryKey = SwiftCachingKeyQueryTaskKey(casOptions: casOptions, cacheKeys: plannedJob.driverJob.cacheKeys, compilerLocation: compilerLocation)
        dynamicExecutionDelegate.requestDynamicTask(
            toolIdentifier: SwiftCachingMaterializeKeyTaskAction.toolIdentifier,
            taskKey: .swiftCachingMaterializeKey(cacheQueryKey),
            taskID: taskID,
            singleUse: true,
            workingDirectory: Path(""),
            environment: .init(),
            forTarget: nil,
            priority: .network,
            showEnvironment: false,
            reason: .wasCompilationCachingQuery)
        return true
    }

    package static func probeCache<Operations: SwiftCacheOperations>(
        operations: Operations,
        cacheKeys: [String],
        expectedOutputKindGroups: [[String]],
        isCancelled: () -> Bool = { false }
    ) throws -> SwiftCacheProbeResult<Operations.Compilation> {
        guard !cacheKeys.isEmpty else {
            return .miss(.missingKey)
        }
        guard cacheKeys.count == expectedOutputKindGroups.count,
              expectedOutputKindGroups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(supportedCachedFileOutputKinds.contains) }) else {
            return .miss(.unsupportedOutput)
        }

        var compilations: [Operations.Compilation] = []
        var outputCount = 0
        compilations.reserveCapacity(cacheKeys.count)
        for (cacheKey, expectedOutputKindNames) in zip(cacheKeys, expectedOutputKindGroups) {
            if isCancelled() { throw CancellationError() }
            let queriedCompilation = try operations.queryLocalCacheKey(cacheKey)
            if isCancelled() { throw CancellationError() }
            guard let compilation = queriedCompilation else {
                return .miss(.missingKey)
            }
            let outputs = try operations.cachedOutputs(for: compilation)
            if isCancelled() { throw CancellationError() }
            guard !outputs.isEmpty, outputs.allSatisfy(\.isMaterialized) else {
                return .miss(.nonMaterializedOutput)
            }
            guard let admittedOutputKindNames = admittedCachedFileOutputKinds(outputs),
                  admittedOutputKindNames == expectedOutputKindNames else {
                return .miss(.unsupportedOutput)
            }
            outputCount += admittedOutputKindNames.count
            compilations.append(compilation)
        }
        return .hit(compilations: compilations, outputCount: outputCount)
    }

    /// Cache output names are part of the compiler CAS protocol. Keep the
    /// materializing allowlist explicit so a new or ambiguous output kind fails
    /// closed until its filesystem behavior is understood and tested.
    private static let supportedCachedFileOutputKinds: Set<String> = [
        "abi-baseline-json", "api-baseline-json", "api-descriptor-json",
        "assembly", "ast-dump", "autolink", "bitstream-opt-record",
        "const-values", "dependencies", "diagnostics",
        "emit-module-dependencies", "emit-module-diagnostics", "imported-modules",
        "json-dependencies", "json-module-artifacts", "json-supported-features",
        "json-supported-swift-features", "json-target-info", "llvm-bc", "llvm-ir",
        "module-semantic-info", "module-trace", "modulemap", "object", "objc-header", "pch", "pcm",
        "private-swiftinterface", "package-swiftinterface", "raw-llvm-ir", "raw-sib",
        "raw-sil", "remap", "sib", "sil", "swift-dependencies", "swiftdoc",
        "swiftinterface", "swiftmodule", "swift-module-summary", "swiftsourceinfo", "tbd",
        "yaml-opt-record",
    ]

    /// Cached diagnostics are replayed as diagnostics/streams, not as a planned
    /// file output. At most one is accepted, and only after every file output.
    private static func admittedCachedFileOutputKinds(_ outputs: [SwiftCacheCachedOutput]) -> [String]? {
        var fileKinds: [String] = []
        var sawCachedDiagnostics = false
        for output in outputs {
            if output.kindName == "cached-diagnostics" {
                guard !sawCachedDiagnostics else { return nil }
                sawCachedDiagnostics = true
                continue
            }
            guard !sawCachedDiagnostics,
                  supportedCachedFileOutputKinds.contains(output.kindName) else {
                return nil
            }
            fileKinds.append(output.kindName)
        }
        return fileKinds
    }

    /// Replays in compiler-key order. Cached streams are discarded immediately
    /// unless capture is requested, in which case they are returned in that same
    /// order. Callers must not publish a partial array if a later replay fails.
    package static func replayCache<Operations: SwiftCacheOperations>(
        operations: Operations,
        compilations: [Operations.Compilation],
        commandLine: [String],
        captureStreams: Bool = false,
        pauseBeforeMaterialization: (() throws -> Void)? = nil,
        isCancelled: () -> Bool = { false },
        isQuarantined: () -> Bool = { false }
    ) throws -> [SwiftCacheReplayStreams]? {
        if isQuarantined() { throw SwiftAcceleratorCacheQuarantinedError() }
        if isCancelled() { throw CancellationError() }
        let instance = try operations.createReplayInstance(commandLine: Array(commandLine.dropFirst()))
        if isQuarantined() { throw SwiftAcceleratorCacheQuarantinedError() }
        if isCancelled() { throw CancellationError() }
        try pauseBeforeMaterialization?()
        if isQuarantined() { throw SwiftAcceleratorCacheQuarantinedError() }
        if isCancelled() { throw CancellationError() }
        var streams: [SwiftCacheReplayStreams]? = captureStreams ? [] : nil
        streams?.reserveCapacity(compilations.count)
        for compilation in compilations {
            if isQuarantined() { throw SwiftAcceleratorCacheQuarantinedError() }
            if isCancelled() { throw CancellationError() }
            let replayStreams = try operations.replayCompilation(compilation, using: instance)
            streams?.append(replayStreams)
            if isQuarantined() { throw SwiftAcceleratorCacheQuarantinedError() }
            if isCancelled() { throw CancellationError() }
        }
        return streams
    }

    /// Checks only output presence and regular-file shape. The unsafe trust
    /// experiment intentionally avoids content reads and hashing.
    package static func validateReplayCompleteness(
        _ paths: [Path],
        fs: any FSProxy
    ) throws {
        guard !paths.isEmpty, Set(paths).count == paths.count else {
            throw SwiftCacheOutputError.missingOutput
        }
        for path in paths {
            guard fs.exists(path),
                  !isSymlink(path, fs: fs),
                  try fs.getFileInfo(path).isFile else {
                throw SwiftCacheOutputError.missingOutput
            }
        }
    }

    package static func validateOutputDestinations(_ paths: [Path], fs: any FSProxy) throws {
        guard !paths.isEmpty, Set(paths).count == paths.count, paths.allSatisfy(\.isAbsolute) else {
            throw SwiftCacheOutputError.unsupportedOutput
        }
        for path in paths where fs.exists(path) || isSymlink(path, fs: fs) {
            guard !isSymlink(path, fs: fs), try fs.getFileInfo(path).isFile else {
                throw SwiftCacheOutputError.unsupportedOutput
            }
        }
    }

    /// Generated Objective-C headers may be shared by multiple Swift driver
    /// jobs. Verify mode must not replay or scrub such an output.
    package static func hasSharedObjectiveCHeaderOutput(
        commandLine: [String],
        plannedOutputs: [Path]
    ) -> Bool {
        guard commandLine.count > 1 else { return false }
        let outputSet = Set(plannedOutputs)
        for index in commandLine.indices.dropLast() where commandLine[index] == "-emit-objc-header-path" {
            let path = Path(commandLine[commandLine.index(after: index)])
            if path.isAbsolute, outputSet.contains(path) {
                return true
            }
        }
        return false
    }

    package static func makeOutputManifest(
        _ paths: [Path],
        fs: any FSProxy,
        isCancelled: () -> Bool = { false }
    ) throws -> SwiftCacheOutputManifest {
        var entries: [SwiftCacheOutputManifest.Entry] = []
        entries.reserveCapacity(paths.count)
        for (ordinal, path) in paths.enumerated() {
            if isCancelled() { throw CancellationError() }
            guard fs.exists(path) else {
                throw SwiftCacheOutputError.missingOutput
            }
            guard !isSymlink(path, fs: fs), try fs.getFileInfo(path).isFile else {
                throw SwiftCacheOutputError.unsupportedOutput
            }
            let permissions = try fs.getLinkFileInfo(path).permissions
            let bytes = try fs.read(path)
            if isCancelled() { throw CancellationError() }
            let hash = SHA256Context()
            hash.add(bytes: bytes)
            entries.append(.init(
                ordinal: ordinal,
                fileKind: .regularFile,
                permissions: permissions,
                byteCount: Int64(bytes.count),
                digest: hash.signature
            ))
        }
        if isCancelled() { throw CancellationError() }
        return SwiftCacheOutputManifest(entries: entries)
    }

    #if canImport(Darwin)
    package static func makeOutputManifest(
        _ session: DescriptorRelativeFileOperations.OutputAccessSession,
        replayedOutputs: Bool,
        isCancelled: () -> Bool = { false }
    ) throws -> SwiftCacheOutputManifest {
        var entries: [SwiftCacheOutputManifest.Entry] = []
        entries.reserveCapacity(session.count)
        for ordinal in 0..<session.count {
            if isCancelled() || _Concurrency.Task<Never, Never>.isCancelled { throw CancellationError() }
            let snapshot = if replayedOutputs {
                try session.snapshotReplayedOutput(at: ordinal, isCancelled: isCancelled)
            } else {
                try session.snapshotCurrentOutput(at: ordinal, isCancelled: isCancelled)
            }
            entries.append(.init(
                ordinal: ordinal,
                fileKind: .regularFile,
                permissions: snapshot.metadata.permissions,
                byteCount: snapshot.metadata.byteCount,
                digest: snapshot.digest
            ))
        }
        if isCancelled() || _Concurrency.Task<Never, Never>.isCancelled { throw CancellationError() }
        return SwiftCacheOutputManifest(entries: entries)
    }
    #endif

    /// Scrubs the complete planned output list, including outputs that replay did
    /// not report writing. A failed removal is a correctness failure, not fallback.
    package static func scrubOutputs(
        _ paths: [Path],
        fs: any FSProxy,
        isCancelled: () -> Bool = { false }
    ) throws {
        var failed = false
        var cancelled = isCancelled()
        for path in paths where fs.exists(path) || isSymlink(path, fs: fs) {
            cancelled = cancelled || isCancelled()
            do {
                try fs.remove(path)
            } catch {
                failed = true
                continue
            }
            if fs.exists(path) || isSymlink(path, fs: fs) {
                failed = true
            }
            cancelled = cancelled || isCancelled()
        }
        if failed {
            throw SwiftCacheOutputError.scrubFailed
        }
        if cancelled || isCancelled() {
            throw CancellationError()
        }
    }

    #if canImport(Darwin)
    package static func scrubAdmittedOutputs(
        _ session: DescriptorRelativeFileOperations.OutputAccessSession,
        isCancelled: () -> Bool = { false }
    ) throws {
        try session.scrubAdmittedOutputs(isCancelled: isCancelled)
    }

    package static func scrubReplayOutputs(
        _ session: DescriptorRelativeFileOperations.OutputAccessSession,
        isCancelled: () -> Bool = { false }
    ) throws {
        try session.scrubReplayOutputs(isCancelled: isCancelled)
    }
    #endif

    package static func prepareAcceleratorCache<Operations: SwiftCacheOperations>(
        mode: SwiftBuildAcceleratorCacheMode,
        trustAuthorization: SwiftAcceleratorCacheTrustAuthorization? = nil,
        operations: Operations,
        cacheKeys: [String],
        expectedOutputKindGroups: [[String]],
        plannedOutputs: [Path],
        commandLine: [String],
        fs: any FSProxy,
        outputAccessPlan: SwiftCacheOutputAccessPlan? = nil,
        injectedFault: SwiftAcceleratorCacheInjectedFault? = nil,
        claimInjectedFault: ((SwiftAcceleratorCacheInjectedFault) -> Bool)? = nil,
        pauseAtCancellationCheckpoint: ((SwiftAcceleratorCacheCancellationCheckpoint) throws -> Void)? = nil,
        isCancelled: () -> Bool = { false },
        isQuarantined: () -> Bool = { false },
        quarantineCache: () -> Void = {}
    ) -> SwiftAcceleratorCachePreparation {
        #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
        // The experimental binary plus externally selected `trust` mode is the
        // complete activation boundary. No private runtime token is required.
        #else
        guard mode != .trust || trustAuthorization != nil else {
            return .init(outcome: .unauthorizedTrust, lookupDurationNS: 0)
        }
        #endif
        if mode.usesAcceleratorMaterialization && isQuarantined() {
            return .init(outcome: .quarantined, lookupDurationNS: 0)
        }
        if isCancelled() {
            return .init(outcome: .cancelled, lookupDurationNS: 0)
        }
        if mode.usesAcceleratorMaterialization,
           hasSharedObjectiveCHeaderOutput(commandLine: commandLine, plannedOutputs: plannedOutputs) {
            return .init(outcome: .unsupportedOutput, lookupDurationNS: 0)
        }
        guard expectedOutputKindGroups.reduce(0, { $0 + $1.count }) == plannedOutputs.count else {
            return .init(outcome: .unsupportedOutput, lookupDurationNS: 0)
        }
        #if canImport(Darwin)
        if outputAccessPlan != nil,
           (!mode.usesAcceleratorMaterialization || !supportsDescriptorOutputAccessPlan(fs: fs)) {
            return .init(outcome: .unsupportedOutput, lookupDurationNS: 0)
        }
        var activeOutputAccessPlan = outputAccessPlan
        if mode.usesAcceleratorMaterialization && activeOutputAccessPlan == nil {
            do {
                switch try makeLocalFileSystemOutputAccessPlan(
                    paths: plannedOutputs,
                    fs: fs,
                    isCancelled: isCancelled
                ) {
                case .descriptor(let plan):
                    activeOutputAccessPlan = plan
                case .compatibilityFallback:
                    try validateOutputDestinations(plannedOutputs, fs: fs)
                case .unsupportedFileSystem:
                    return .init(outcome: .unsupportedOutput, lookupDurationNS: 0)
                }
            } catch is CancellationError {
                return .init(outcome: .cancelled, lookupDurationNS: 0)
            } catch {
                return .init(outcome: .unsupportedOutput, lookupDurationNS: 0)
            }
        }
        if let activeOutputAccessPlan, activeOutputAccessPlan.paths != plannedOutputs {
            return .init(outcome: .unsupportedOutput, lookupDurationNS: 0)
        }
        let outputAccessSession: DescriptorRelativeFileOperations.OutputAccessSession?
        do {
            outputAccessSession = try activeOutputAccessPlan?.openSession(
                leafExpectation: .admitted,
                isCancelled: isCancelled
            )
        } catch is CancellationError {
            return .init(outcome: .cancelled, lookupDurationNS: 0)
        } catch {
            quarantineCache()
            return .init(outcome: .scrubFailure, lookupDurationNS: 0, scrubSucceeded: false)
        }
        defer { outputAccessSession?.close() }
        #else
        if outputAccessPlan != nil {
            return .init(outcome: .unsupportedOutput, lookupDurationNS: 0)
        }
        if mode.usesAcceleratorMaterialization {
            do {
                switch try makeLocalFileSystemOutputAccessPlan(
                    paths: plannedOutputs,
                    fs: fs,
                    isCancelled: isCancelled
                ) {
                case .compatibilityFallback:
                    try validateOutputDestinations(plannedOutputs, fs: fs)
                case .unsupportedFileSystem:
                    return .init(outcome: .unsupportedOutput, lookupDurationNS: 0)
                }
            } catch is CancellationError {
                return .init(outcome: .cancelled, lookupDurationNS: 0)
            } catch {
                return .init(outcome: .unsupportedOutput, lookupDurationNS: 0)
            }
        }
        #endif
        // The runtime controller already enforces this boundary. Keep the
        // nonserialized test seam equally narrow if it is called directly.
        let activeInjectedFault = mode == .verify ? injectedFault : nil
        let activeCancellationPause = mode == .verify ? pauseAtCancellationCheckpoint : nil
        let claimAtCheckpoint: (SwiftAcceleratorCacheInjectedFault) -> Bool = { checkpoint in
            activeInjectedFault == checkpoint || (mode == .verify && claimInjectedFault?(checkpoint) == true)
        }
        let lookupTimer = ElapsedTimer()
        let probe: SwiftCacheProbeResult<Operations.Compilation>
        do {
            if claimAtCheckpoint(.queryError) {
                throw SwiftAcceleratorCacheInjectedError.injected
            }
            probe = try probeCache(
                operations: operations,
                cacheKeys: cacheKeys,
                expectedOutputKindGroups: expectedOutputKindGroups,
                isCancelled: isCancelled
            )
            try activeCancellationPause?(.queryStage)
        } catch is CancellationError {
            return .init(outcome: .cancelled, lookupDurationNS: lookupTimer.elapsedTime().nanoseconds)
        } catch {
            return .init(outcome: .queryError, lookupDurationNS: lookupTimer.elapsedTime().nanoseconds)
        }
        let lookupDurationNS = lookupTimer.elapsedTime().nanoseconds
        if isCancelled() {
            return .init(outcome: .cancelled, lookupDurationNS: lookupDurationNS)
        }

        switch probe {
        case .miss(.unsupportedOutput):
            return .init(outcome: .unsupportedOutput, lookupDurationNS: lookupDurationNS)
        case .miss:
            #if canImport(Darwin)
            if let activeOutputAccessPlan {
                do {
                    try activeOutputAccessPlan.revalidateCurrentNamespace(
                        leafExpectation: .admitted,
                        isCancelled: isCancelled
                    )
                } catch is CancellationError {
                    return .init(outcome: .cancelled, lookupDurationNS: lookupDurationNS)
                } catch {
                    quarantineCache()
                    return .init(
                        outcome: .scrubFailure,
                        lookupDurationNS: lookupDurationNS,
                        scrubSucceeded: false
                    )
                }
            }
            #endif
            return .init(outcome: .miss, lookupDurationNS: lookupDurationNS)
        case .hit(_, let outputCount) where mode == .observe:
            return .init(outcome: .wouldHit, lookupDurationNS: lookupDurationNS, cachedOutputCount: outputCount)
        case .hit(let compilations, let outputCount):
            if isQuarantined() {
                return .init(outcome: .quarantined, lookupDurationNS: lookupDurationNS, cachedOutputCount: outputCount)
            }
            // Remove every valid preexisting output before replay. Otherwise an
            // incomplete replay could make a stale file look like a cache hit.
            let preScrubTimer = ElapsedTimer()
            do {
                #if canImport(Darwin)
                if let outputAccessSession {
                    try scrubAdmittedOutputs(outputAccessSession, isCancelled: isCancelled)
                } else {
                    try scrubOutputs(plannedOutputs, fs: fs, isCancelled: isCancelled)
                }
                #else
                try scrubOutputs(plannedOutputs, fs: fs, isCancelled: isCancelled)
                #endif
            } catch is CancellationError {
                return .init(
                    outcome: .cancelled,
                    lookupDurationNS: lookupDurationNS,
                    scrubDurationNS: preScrubTimer.elapsedTime().nanoseconds,
                    scrubSucceeded: true,
                    cachedOutputCount: outputCount
                )
            } catch {
                quarantineCache()
                return .init(
                    outcome: .scrubFailure,
                    lookupDurationNS: lookupDurationNS,
                    scrubDurationNS: preScrubTimer.elapsedTime().nanoseconds,
                    scrubSucceeded: false,
                    cachedOutputCount: outputCount
                )
            }
            var totalScrubDurationNS = preScrubTimer.elapsedTime().nanoseconds
            if isCancelled() {
                return .init(
                    outcome: .cancelled,
                    lookupDurationNS: lookupDurationNS,
                    scrubDurationNS: totalScrubDurationNS,
                    scrubSucceeded: true,
                    cachedOutputCount: outputCount
                )
            }

            var outcome: SwiftAcceleratorCachePreparationOutcome = .verificationReady
            var shadowManifest: SwiftCacheOutputManifest?
            let replayTimer = ElapsedTimer()
            var replayFailure: (any Error)?
            var capturedReplayStreams: [SwiftCacheReplayStreams]?
            #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
            let captureReplayStreams = mode == .trust
            #else
            let captureReplayStreams = false
            #endif
            #if canImport(Darwin)
            var replayIdentitiesCaptured = false
            #endif
            do {
                if claimAtCheckpoint(.replayError) {
                    throw SwiftAcceleratorCacheInjectedError.injected
                }
                capturedReplayStreams = try replayCache(
                    operations: operations,
                    compilations: compilations,
                    commandLine: commandLine,
                    captureStreams: captureReplayStreams,
                    pauseBeforeMaterialization: {
                        try activeCancellationPause?(.replayStage)
                    },
                    isCancelled: isCancelled,
                    isQuarantined: isQuarantined
                )
                #if canImport(Darwin)
                if let outputAccessSession {
                    try outputAccessSession.captureReplayOutputs()
                    replayIdentitiesCaptured = true
                }
                #endif
                #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
                if mode == .trust {
                    #if canImport(Darwin)
                    if let outputAccessSession {
                        try outputAccessSession.validateCompleteReplayOutputs(expectedCount: plannedOutputs.count)
                    } else {
                        try validateReplayCompleteness(plannedOutputs, fs: fs)
                    }
                    #else
                    try validateReplayCompleteness(plannedOutputs, fs: fs)
                    #endif
                }
                #endif
                if isQuarantined() { throw SwiftAcceleratorCacheQuarantinedError() }
                try activeCancellationPause?(.postMaterialization)
            } catch {
                replayFailure = error
            }

            #if canImport(Darwin)
            if let outputAccessSession, !replayIdentitiesCaptured {
                do {
                    try outputAccessSession.captureReplayOutputs()
                    replayIdentitiesCaptured = true
                } catch {
                    replayFailure = error
                }
            }
            #endif
            if replayFailure is CancellationError {
                outcome = .cancelled
            } else if replayFailure is SwiftAcceleratorCacheQuarantinedError {
                outcome = .quarantined
            } else if replayFailure != nil {
                quarantineCache()
                outcome = .replayError
            }
            let replayDurationNS = replayTimer.elapsedTime().nanoseconds

            #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
            if mode == .trust, outcome == .verificationReady {
                if isCancelled() {
                    outcome = .cancelled
                } else if isQuarantined() {
                    outcome = .quarantined
                } else if let capturedReplayStreams,
                          capturedReplayStreams.count == compilations.count {
                    return .init(
                        outcome: .unsafeTrustHit,
                        lookupDurationNS: lookupDurationNS,
                        replayDurationNS: replayDurationNS,
                        scrubDurationNS: totalScrubDurationNS,
                        cachedOutputCount: outputCount,
                        replayStreams: capturedReplayStreams
                    )
                } else {
                    quarantineCache()
                    outcome = .replayError
                }
            }
            #endif

            var manifestDurationNS: UInt64?
            if outcome == .verificationReady && !isCancelled() {
                let manifestTimer = ElapsedTimer()
                do {
                    if isQuarantined() { throw SwiftAcceleratorCacheQuarantinedError() }
                    if claimAtCheckpoint(.manifestError) {
                        throw SwiftAcceleratorCacheInjectedError.injected
                    }
                    #if canImport(Darwin)
                    if let outputAccessSession {
                        shadowManifest = try makeOutputManifest(
                            outputAccessSession,
                            replayedOutputs: true,
                            isCancelled: isCancelled
                        )
                    } else {
                        shadowManifest = try makeOutputManifest(plannedOutputs, fs: fs, isCancelled: isCancelled)
                    }
                    #else
                    shadowManifest = try makeOutputManifest(plannedOutputs, fs: fs, isCancelled: isCancelled)
                    #endif
                    if isQuarantined() { throw SwiftAcceleratorCacheQuarantinedError() }
                } catch is CancellationError {
                    outcome = .cancelled
                } catch is SwiftAcceleratorCacheQuarantinedError {
                    outcome = .quarantined
                    shadowManifest = nil
                } catch {
                    quarantineCache()
                    outcome = .manifestError
                }
                manifestDurationNS = manifestTimer.elapsedTime().nanoseconds
                if isCancelled() {
                    outcome = .cancelled
                    shadowManifest = nil
                }
            } else if outcome == .verificationReady {
                outcome = .cancelled
            }

            let scrubTimer = ElapsedTimer()
            do {
                #if canImport(Darwin)
                if let outputAccessSession {
                    try scrubReplayOutputs(outputAccessSession, isCancelled: isCancelled)
                } else {
                    try scrubOutputs(plannedOutputs, fs: fs, isCancelled: isCancelled)
                }
                #else
                try scrubOutputs(plannedOutputs, fs: fs, isCancelled: isCancelled)
                #endif
            } catch is CancellationError {
                totalScrubDurationNS += scrubTimer.elapsedTime().nanoseconds
                return .init(
                    outcome: .cancelled,
                    lookupDurationNS: lookupDurationNS,
                    replayDurationNS: replayDurationNS,
                    manifestDurationNS: manifestDurationNS,
                    scrubDurationNS: totalScrubDurationNS,
                    scrubSucceeded: true,
                    cachedOutputCount: outputCount,
                    shadowManifest: nil
                )
            } catch {
                quarantineCache()
                totalScrubDurationNS += scrubTimer.elapsedTime().nanoseconds
                return .init(
                    outcome: .scrubFailure,
                    lookupDurationNS: lookupDurationNS,
                    replayDurationNS: replayDurationNS,
                    manifestDurationNS: manifestDurationNS,
                    scrubDurationNS: totalScrubDurationNS,
                    scrubSucceeded: false,
                    cachedOutputCount: outputCount,
                    shadowManifest: nil
                )
            }
            totalScrubDurationNS += scrubTimer.elapsedTime().nanoseconds
            #if canImport(Darwin)
            if let activeOutputAccessPlan {
                do {
                    try activeOutputAccessPlan.revalidateCurrentNamespace(
                        leafExpectation: .absent,
                        isCancelled: isCancelled
                    )
                } catch is CancellationError {
                    return .init(
                        outcome: .cancelled,
                        lookupDurationNS: lookupDurationNS,
                        replayDurationNS: replayDurationNS,
                        manifestDurationNS: manifestDurationNS,
                        scrubDurationNS: totalScrubDurationNS,
                        scrubSucceeded: true,
                        cachedOutputCount: outputCount,
                        shadowManifest: nil
                    )
                } catch {
                    quarantineCache()
                    return .init(
                        outcome: .scrubFailure,
                        lookupDurationNS: lookupDurationNS,
                        replayDurationNS: replayDurationNS,
                        manifestDurationNS: manifestDurationNS,
                        scrubDurationNS: totalScrubDurationNS,
                        scrubSucceeded: false,
                        cachedOutputCount: outputCount,
                        shadowManifest: nil
                    )
                }
            }
            #endif
            return .init(
                outcome: outcome,
                lookupDurationNS: lookupDurationNS,
                replayDurationNS: replayDurationNS,
                manifestDurationNS: manifestDurationNS,
                scrubDurationNS: totalScrubDurationNS,
                scrubSucceeded: true,
                cachedOutputCount: outputCount,
                shadowManifest: shadowManifest
            )
        }
    }

    package static func compareFreshOutputs(
        shadowManifest: SwiftCacheOutputManifest,
        plannedOutputs: [Path],
        fs: any FSProxy
    ) -> SwiftAcceleratorCacheComparison {
        let timer = ElapsedTimer()
        do {
            let freshManifest = try makeOutputManifest(plannedOutputs, fs: fs)
            return .init(
                freshManifest: freshManifest,
                mismatchCount: shadowManifest.mismatchCount(comparedTo: freshManifest),
                comparedBytes: UInt64(min(shadowManifest.totalBytes, freshManifest.totalBytes)),
                durationNS: timer.elapsedTime().nanoseconds
            )
        } catch {
            return .init(
                freshManifest: nil,
                mismatchCount: max(1, plannedOutputs.count),
                comparedBytes: 0,
                durationNS: timer.elapsedTime().nanoseconds
            )
        }
    }

    #if canImport(Darwin)
    package static func compareFreshOutputs(
        shadowManifest: SwiftCacheOutputManifest,
        outputAccessPlan: SwiftCacheOutputAccessPlan,
        isCancelled: () -> Bool = { false }
    ) throws -> SwiftAcceleratorCacheComparison {
        let timer = ElapsedTimer()
        let session = try outputAccessPlan.openSession(
            leafExpectation: .unchecked,
            isCancelled: isCancelled
        )
        defer { session.close() }
        do {
            let freshManifest = try makeOutputManifest(
                session,
                replayedOutputs: false,
                isCancelled: isCancelled
            )
            return .init(
                freshManifest: freshManifest,
                mismatchCount: shadowManifest.mismatchCount(comparedTo: freshManifest),
                comparedBytes: UInt64(min(shadowManifest.totalBytes, freshManifest.totalBytes)),
                durationNS: timer.elapsedTime().nanoseconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(
                freshManifest: nil,
                mismatchCount: max(1, outputAccessPlan.count),
                comparedBytes: 0,
                durationNS: timer.elapsedTime().nanoseconds
            )
        }
    }
    #endif

    package static func cachePreparationIsFatal(
        _ outcome: SwiftAcceleratorCachePreparationOutcome,
        strictCASErrors: Bool
    ) -> Bool {
        if outcome == .scrubFailure {
            return true
        }
        guard strictCASErrors else {
            return false
        }
        switch outcome {
        case .unavailable, .queryError, .replayError, .manifestError:
            return true
        case .unauthorizedTrust, .quarantined, .unsupportedOutput, .cancelled, .miss, .wouldHit, .verificationReady, .unsafeTrustHit, .scrubFailure:
            return false
        }
    }

    package static func shouldAcceptUnsafeTrustHit(
        mode: SwiftBuildAcceleratorCacheMode,
        outcome: SwiftAcceleratorCachePreparationOutcome
    ) -> Bool {
        #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT
        mode == .trust && outcome == .unsafeTrustHit
        #else
        false
        #endif
    }

    /// Upstream replay is reserved for stock mode. Observe and verify always
    /// reach the authoritative frontend, including when policy-excluded.
    package static func usesStockCacheReplayPath(mode: SwiftBuildAcceleratorCacheMode) -> Bool {
        mode == .stock
    }

    package static func shouldCancelBeforeFrontend(
        mode: SwiftBuildAcceleratorCacheMode,
        isCancelled: Bool
    ) -> Bool {
        mode.isAcceleratorEnabled && isCancelled
    }

    #if SWIFT_BUILD_ACCELERATOR_FAULT_INJECTION
    /// Returns a path-free, opaque identity for selecting one planned Swift
    /// job in a dedicated fault-injection build. The inputs are deliberately
    /// limited to stable planning identity; command lines, cache keys, and
    /// filesystem paths are not accepted by this boundary. Keep this identity
    /// stable across fresh service processes; in particular, do not add values
    /// derived from Swift's process-seeded `hashValue`.
    package static func acceleratorFaultSelector(
        targetIdentity: String?,
        arch: String,
        variant: String?,
        jobKey: LibSwiftDriver.JobKey
    ) -> String {
        let context = SHA256Context()

        func addField(_ bytes: [UInt8]) {
            context.add(number: UInt64(bytes.count))
            context.add(bytes: bytes)
        }
        func addField(_ value: String) {
            addField(Array(value.utf8))
        }

        addField("swift-build-accelerator-fault-selector-v2")
        addField(targetIdentity ?? "explicit-dependency")
        addField(arch)
        addField(variant ?? "")
        switch jobKey {
        case .targetJob(let index):
            addField("target")
            addField(String(index))
        case .explicitDependencyJob(let index):
            addField("explicit")
            addField(String(index))
        }
        return String(decoding: context.signature.bytes, as: UTF8.self)
    }
    #endif

    private static func isSymlink(_ path: Path, fs: any FSProxy) -> Bool {
        var destinationExists = false
        return fs.isSymlink(path, &destinationExists)
    }

    /// Attempts to replay a previously cached compilation, using data from the local CAS.
    ///
    /// - Returns: `true` if the the cached compilation outputs were found and replayed, `false` otherwise.
    static func replayCachedCommand(cas: SwiftCASDatabases,
                                    plannedJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob,
                                    commandLine: [String],
                                    dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
                                    outputDelegate: any TaskOutputDelegate,
                                    casOptions: CASOptions,
                                    reportCacheKeys: Bool
    ) async throws -> Bool {
        let enableDiagnosticRemarks = casOptions.enableDiagnosticRemarks
        let cacheKeys = plannedJob.driverJob.cacheKeys
        guard !cacheKeys.isEmpty else { return false }

        if reportCacheKeys {
            for cacheKey in cacheKeys {
                outputDelegate.emitCacheKey(cacheKey, source: .swift, casOptions: casOptions)
            }
        }

        func replayCachedCommandImpl() async throws -> Bool {
            // Query cache key.
            var comps: [SwiftCachedCompilation] = []
            for cacheKey in cacheKeys {
                // If any of the key misses, return cache miss.
                guard let comp = try cas.queryLocalCacheKey(cacheKey) else {
                    if enableDiagnosticRemarks {
                        outputDelegate.note("local cache miss for key: \(cacheKey)")
                    }
                    return false
                }
                if enableDiagnosticRemarks {
                    outputDelegate.note("local cache found for key: \(cacheKey)")
                }
                // Check all outputs are materialized.
                // Doing the check immediately after the key allows associating the output remarks with the right key.
                for output in try comp.getOutputs() {
                    if !output.isMaterialized {
                        if enableDiagnosticRemarks {
                            outputDelegate.note("cached output \(output.kindName) not available locally: \(output.casID)")
                        }
                        return false
                    }
                    if enableDiagnosticRemarks {
                        outputDelegate.note("using CAS output \(output.kindName): \(output.casID)")
                    }
                }
                comps.append(comp)
            }

            // Replay after all checks are done.
            let instance = try cas.createReplayInstance(cmd: Array(commandLine.dropFirst(1))) // drop executable name
            let replayResults: [Result<SwiftCacheReplayResult, any Error>] = await comps.concurrentMap(maximumParallelism: 10) { comp in
                do {
                    return .success(try cas.replayCompilation(instance: instance, compilation: comp))
                } catch {
                    return .failure(error)
                }
            }
            for replayResult in replayResults {
                let result = try replayResult.get()
                // emit stdout/stderr
                outputDelegate.emitOutput(ByteString(encodingAsUTF8: try result.getStdOut()))
                outputDelegate.emitOutput(ByteString(encodingAsUTF8: try result.getStdErr()))
            }
            return true
        }

        let result = try await replayCachedCommandImpl()
        if enableDiagnosticRemarks {
            outputDelegate.note("replay cache \(result ? "hit" : "miss")")
        }
        if result {
            outputDelegate.incrementCounter(.swiftCacheHits)
            outputDelegate.incrementTaskCounter(.cacheHits)
            outputDelegate.emitOutput("Cache hit\n")
        } else {
            outputDelegate.incrementCounter(.swiftCacheMisses)
            outputDelegate.incrementTaskCounter(.cacheMisses)
            outputDelegate.emitOutput("Cache miss\n")
        }
        return result
    }

    static func upload(cas: SwiftCASDatabases,
                       plannedJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob,
                       dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
                       outputDelegate: any TaskOutputDelegate,
                       enableDiagnosticRemarks: Bool,
                       enableStrictCASErrors: Bool
    ) throws {
        let cacheKeys = plannedJob.driverJob.cacheKeys
        guard !cacheKeys.isEmpty else { return }

        let comps = try cacheKeys.compactMap { cacheKey -> (String, SwiftCachedCompilation)? in
            guard let cachedComp = try cas.queryLocalCacheKey(cacheKey) else {
                // This should not happen for swiftlang. Issue an warning.
                outputDelegate.warning("compilation was not cached for key: \(cacheKey)")
                return nil
            }
            return (cacheKey, cachedComp)
        }
        for (cacheKey, cachedComp) in comps {
            dynamicExecutionDelegate.operationContext.compilationCachingUploader.upload(
                swiftCompilation: cachedComp,
                cacheKey: cacheKey,
                enableDiagnosticRemarks: enableDiagnosticRemarks,
                enableStrictCASErrors: enableStrictCASErrors,
                activityReporter: dynamicExecutionDelegate)
        }
    }
}
