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

package import Foundation
import struct Dispatch.DispatchTime

#if canImport(System)
import System
#else
import SystemPackage
#endif

package import SWBBuildSystem
package import SWBCore
package import SWBProtocol
import SWBTaskExecution
package import SWBUtil
import Synchronization

/// The deliberately small JSON value model used by the trace side channel.
/// Keeping payloads typed and `Sendable` ensures no build-system objects or raw
/// paths cross onto the writer queue.
package enum AcceleratorTraceValue: Encodable, Sendable, Equatable {
    case string(String)
    case unsigned(UInt64)
    case integer(Int)
    case boolean(Bool)
    case array([AcceleratorTraceValue])
    case object([String: AcceleratorTraceValue])
    case null

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// Injectable only so the recorder's failure and backpressure behavior can be
/// tested without touching the filesystem.
package protocol AcceleratorTraceSink: Sendable {
    func write(_ data: Data) throws
    func close() throws
}

private final class AcceleratorFileTraceSink: AcceleratorTraceSink, @unchecked Sendable {
    private let descriptor: FileDescriptor

    init(descriptor: FileDescriptor) {
        self.descriptor = descriptor
    }

    func write(_ data: Data) throws {
        try descriptor.writeAll(data)
    }

    func close() throws {
        try descriptor.close()
    }
}

/// An observation-only, bounded, asynchronous NDJSON recorder.
///
/// Callback methods never perform file I/O and all failures are contained
/// inside the recorder. Tracing is disabled unless explicitly enabled through
/// ``Configuration``.
package final class AcceleratorTraceWriter: @unchecked Sendable {
    package enum PrivacyMode: String, Sendable {
        case redacted
        case debug

        var traceValue: String {
            switch self {
            case .redacted: return "local_redacted"
            case .debug: return "local_debug"
            }
        }
    }

    package enum UpToDateReason: String, Sendable {
        case buildDatabase = "build_database"
        case batched
        case other
    }

    package struct Configuration: Sendable, Equatable {
        package static let defaultCapacity = 8192
        package static let capacityRange = 256...65536

        package let outputDirectory: Path
        package let capacity: Int
        package let privacyMode: PrivacyMode

        package init(outputDirectory: Path, capacity: Int = defaultCapacity, privacyMode: PrivacyMode = .redacted) {
            self.outputDirectory = outputDirectory
            self.capacity = min(max(capacity, Self.capacityRange.lowerBound), Self.capacityRange.upperBound)
            self.privacyMode = privacyMode
        }

        package init?(environment: [String: String]) {
            guard let enabled = environment["SWIFT_BUILD_ACCELERATOR_TRACE"],
                  ["1", "YES", "true"].contains(enabled),
                  let pathString = environment["SWIFT_BUILD_ACCELERATOR_TRACE_PATH"],
                  !pathString.isEmpty else {
                return nil
            }

            let path = Path(pathString)
            guard path.isAbsolute else { return nil }

            let parsedCapacity = environment["SWIFT_BUILD_ACCELERATOR_TRACE_CAPACITY"].flatMap(Int.init)
            let capacity = parsedCapacity.map {
                min(max($0, Self.capacityRange.lowerBound), Self.capacityRange.upperBound)
            } ?? Self.defaultCapacity
            let privacyMode: PrivacyMode = environment["SWIFT_BUILD_ACCELERATOR_TRACE_PRIVACY"] == "debug" ? .debug : .redacted

            self.init(outputDirectory: path, capacity: capacity, privacyMode: privacyMode)
        }
    }

    package struct Snapshot: Sendable, Equatable {
        package let pendingEventCount: Int
        package let droppedEventCount: UInt64
        package let writerErrorCount: UInt64
        package let disabled: Bool
    }

    private struct Event: Encodable, Sendable {
        let schemaMajor = 1
        let schemaMinor = 0
        let event: String
        let buildID: String
        let sequence: UInt64
        let timestampNS: UInt64
        let payload: [String: AcceleratorTraceValue]

        enum CodingKeys: String, CodingKey {
            case schemaMajor = "schema_major"
            case schemaMinor = "schema_minor"
            case event
            case buildID = "build_id"
            case sequence
            case timestampNS = "timestamp_ns"
            case payload
        }
    }

    private struct State: Sendable {
        var sequence: UInt64 = 0
        var pending: [Event] = []
        var pendingIndex = 0
        var drainScheduled = false
        var finishing = false
        var closed = false
        var disabled = false
        var droppedEventCount: UInt64 = 0
        var writerErrorCount: UInt64 = 0

        var nextTaskID = 1
        var nextTargetID = 1
        var nextNodeID = 1
        var taskIDs: [String: String] = [:]
        var targetIDs: [String: String] = [:]
        var nodeIDs: [String: String] = [:]
        var declaredTasks: Set<String> = []
        var pendingDynamicRequesters: [String: Set<String>] = [:]

        var pendingCount: Int { pending.count - pendingIndex }
    }

    private static let maximumDebugStringLength = 1024
    private static let drainBatchSize = 256

    private let buildID: String
    private let activeBuildID: Int
    private let parameters: BuildParameters
    private let configuration: Configuration
    private let sink: any AcceleratorTraceSink
    private let clock: @Sendable () -> UInt64
    private let originNS: UInt64
    private let state = SWBMutex(State())
    private let queue = SWBQueue(label: "SWBBuildService.AcceleratorTraceWriter", qos: .utility, autoreleaseFrequency: .workItem)
    private let encoder = JSONEncoder(outputFormatting: [.sortedKeys, .withoutEscapingSlashes])

    package static func create(
        buildID: UUID,
        activeBuildID: Int,
        parameters: BuildParameters,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AcceleratorTraceWriter? {
        guard let configuration = Configuration(environment: environment) else { return nil }

        do {
            try FileManager.default.createDirectory(
                atPath: configuration.outputDirectory.str,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.outputDirectory.str)

            let fileName = "swift-build-\(buildID.uuidString.lowercased()).ndjson"
            let path = configuration.outputDirectory.join(fileName)
            let descriptor = try FileDescriptor.open(
                FilePath(path.str),
                .writeOnly,
                options: [.create, .exclusiveCreate, .closeOnExec],
                permissions: [.ownerReadWrite]
            )
            return AcceleratorTraceWriter(
                buildID: buildID,
                activeBuildID: activeBuildID,
                parameters: parameters,
                configuration: configuration,
                sink: AcceleratorFileTraceSink(descriptor: descriptor)
            )
        } catch {
            return nil
        }
    }

    package init(
        buildID: UUID,
        activeBuildID: Int,
        parameters: BuildParameters,
        configuration: Configuration,
        sink: any AcceleratorTraceSink,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.buildID = buildID.uuidString.lowercased()
        self.activeBuildID = activeBuildID
        self.parameters = parameters
        self.configuration = configuration
        self.sink = sink
        self.clock = clock
        self.originNS = clock()
    }

    deinit {
        // A killed or abruptly torn-down service intentionally leaves a partial
        // trace. Closing here is best effort and never waits for queued writes.
        try? sink.close()
    }

    package func buildStarted(operation: SWBBuildSystem.BuildOperation) {
        emit(event: "build_started", payload: [
            "invocation_id": .string(buildID),
            "mode": .string("observe"),
            "action": .string(Self.action(for: parameters)),
            "configuration": .string(Self.configurationName(for: parameters)),
            "destination": .string(Self.destination(for: parameters)),
            "architecture": .string(Self.architecture(for: parameters)),
            "privacy_mode": .string(configuration.privacyMode.traceValue),
            "planning_included": .boolean(false),
            "ready_time_available": .boolean(false),
            "build_description_id": .string("bd1"),
            "declared_task_count": .integer(operation.buildDescription.taskStore.taskCount),
            "capabilities": .array([
                .string("execution_lifecycle"),
                .string("static_manifest_graph"),
                .string("dynamic_request_edges"),
            ]),
        ])

        recordStaticGraph(operation: operation)
    }

    package func buildFinished(status: BuildOperationEnded.Status, metrics: BuildOperationMetrics?) {
        let snapshot = snapshotForTesting
        emit(event: "build_finished", payload: [
            "status": .string(Self.statusName(status)),
            "execution_duration_ns": .unsigned(elapsedNS()),
            "planning_duration_ns": .null,
            "dropped_event_count": .unsigned(snapshot.droppedEventCount),
            "writer_error_count": .unsigned(snapshot.writerErrorCount),
            "compiler_counters": .object([
                "swift_hits": .integer(metrics?.counters[.swiftCacheHits] ?? 0),
                "swift_misses": .integer(metrics?.counters[.swiftCacheMisses] ?? 0),
                "clang_hits": .integer(metrics?.counters[.clangCacheHits] ?? 0),
                "clang_misses": .integer(metrics?.counters[.clangCacheMisses] ?? 0),
            ]),
        ], terminal: true)
        finish()
    }

    package func taskStarted(taskIdentifier: TaskIdentifier, task: any ExecutableTask) {
        ensureTaskDeclared(taskIdentifier: taskIdentifier, task: task, isDynamic: task.isDynamic)
        emit(event: "task_started", payload: [
            "task_id": .string(taskID(for: taskIdentifier)),
            "executor": .string("local"),
            "queue_class": .string("unknown"),
            "ready_time_available": .boolean(false),
        ])
    }

    package func taskFinished(
        taskIdentifier: TaskIdentifier,
        task: any ExecutableTask,
        status: BuildOperationTaskEnded.Status,
        result: TaskResult?,
        duration: ElapsedTimerInterval
    ) {
        ensureTaskDeclared(taskIdentifier: taskIdentifier, task: task, isDynamic: task.isDynamic)
        let metrics = result?.metrics
        emit(event: "task_finished", payload: [
            "task_id": .string(taskID(for: taskIdentifier)),
            "status": .string(Self.statusName(status)),
            "execution_disposition": .string("executed_or_replayed_unknown"),
            "process": .object([
                "wall_duration_ns": .unsigned(duration.nanoseconds),
                "user_cpu_ns": metrics.map { .unsigned(Self.microsecondsToNanoseconds($0.utime)) } ?? .null,
                "system_cpu_ns": metrics.map { .unsigned(Self.microsecondsToNanoseconds($0.stime)) } ?? .null,
                "max_rss_bytes": metrics.map { .unsigned($0.maxRSS) } ?? .null,
                "termination_kind": .string(Self.terminationKind(result)),
            ]),
        ])
    }

    package func taskUpToDate(taskIdentifier: TaskIdentifier, task: any ExecutableTask, reason: UpToDateReason) {
        ensureTaskDeclared(taskIdentifier: taskIdentifier, task: task, isDynamic: task.isDynamic)
        emit(event: "task_up_to_date", payload: [
            "task_id": .string(taskID(for: taskIdentifier)),
            "reason": .string(reason.rawValue),
        ])
    }

    package func previouslyBatchedSubtaskUpToDate(signature: ByteString, target: ConfiguredTarget) {
        // Signatures and target GUIDs are identity inputs only; neither is emitted.
        let identity = "batched:\(target.guid.stringValue):\(signature.bytes.asStableIdentityString)"
        let identifier = TaskIdentifier(rawValue: identity)
        let taskID = taskID(for: identifier)
        emit(event: "task_up_to_date", payload: [
            "task_id": .string(taskID),
            "declared": .boolean(false),
            "reason": .string(UpToDateReason.batched.rawValue),
        ])
    }

    package func taskRequestedDynamicTask(requestingTask: any ExecutableTask, dynamicTaskIdentifier: TaskIdentifier) {
        let requestingIdentifier = requestingTask.identifier
        ensureTaskDeclared(taskIdentifier: requestingIdentifier, task: requestingTask, isDynamic: requestingTask.isDynamic)
        _ = taskID(for: dynamicTaskIdentifier)
        _ = state.withLock { state in
            state.pendingDynamicRequesters[dynamicTaskIdentifier.rawValue, default: []].insert(requestingIdentifier.rawValue)
        }
    }

    package func registeredDynamicTask(task: any ExecutableTask, dynamicTaskIdentifier: TaskIdentifier) {
        ensureTaskDeclared(taskIdentifier: dynamicTaskIdentifier, task: task, isDynamic: true)
        let requesterKeys = state.withLock { state in
            state.pendingDynamicRequesters.removeValue(forKey: dynamicTaskIdentifier.rawValue) ?? []
        }
        for requesterKey in requesterKeys.sorted() {
            emit(event: "task_dependency", payload: [
                "task_id": .string(taskID(forRawKey: requesterKey)),
                "depends_on_task_id": .string(taskID(for: dynamicTaskIdentifier)),
                "edge_kind": .string("dynamic"),
            ])
        }
    }

    /// Test-only escape hatch for validating queue ordering and overflow without
    /// expanding the production event API.
    package func emitForTesting(event: String, payload: [String: AcceleratorTraceValue] = [:]) {
        emit(event: event, payload: payload)
    }

    package var snapshotForTesting: Snapshot {
        state.withLock { state in
            Snapshot(
                pendingEventCount: state.pendingCount,
                droppedEventCount: state.droppedEventCount,
                writerErrorCount: state.writerErrorCount,
                disabled: state.disabled
            )
        }
    }

    package func flushForTesting() {
        queue.blocking_sync {
            self.drain()
        }
    }

    private func finish() {
        let shouldSchedule = state.withLock { state in
            state.finishing = true
            guard !state.disabled, !state.closed, !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        if shouldSchedule {
            queue.async { [self] in drain() }
        }
    }

    private func emit(event: String, payload: [String: AcceleratorTraceValue], terminal: Bool = false) {
        let timestamp = elapsedNS()
        let result = state.withLock { state -> (Event?, Bool) in
            guard !state.disabled, !state.closed, !state.finishing else { return (nil, false) }

            if !terminal && state.pendingCount >= configuration.capacity {
                state.droppedEventCount &+= 1
                return (nil, false)
            }

            state.sequence &+= 1
            let queued = Event(
                event: event,
                buildID: buildID,
                sequence: state.sequence,
                timestampNS: timestamp,
                payload: payload
            )
            state.pending.append(queued)
            if !state.drainScheduled {
                state.drainScheduled = true
                return (queued, true)
            }
            return (queued, false)
        }
        guard result.0 != nil, result.1 else { return }
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            let batchAndClose = state.withLock { state -> ([Event], Bool) in
                guard !state.disabled, !state.closed else {
                    state.drainScheduled = false
                    return ([], false)
                }

                guard state.pendingCount > 0 else {
                    state.drainScheduled = false
                    if state.finishing {
                        state.closed = true
                        return ([], true)
                    }
                    return ([], false)
                }

                let end = min(state.pendingIndex + Self.drainBatchSize, state.pending.count)
                let batch = Array(state.pending[state.pendingIndex..<end])
                state.pendingIndex = end
                if state.pendingIndex == state.pending.count {
                    state.pending.removeAll(keepingCapacity: true)
                    state.pendingIndex = 0
                } else if state.pendingIndex >= Self.drainBatchSize * 4 {
                    state.pending.removeFirst(state.pendingIndex)
                    state.pendingIndex = 0
                }
                return (batch, false)
            }

            if batchAndClose.1 {
                closeSink()
                return
            }
            guard !batchAndClose.0.isEmpty else { return }

            do {
                var data = Data()
                for event in batchAndClose.0 {
                    data.append(try encoder.encode(event))
                    data.append(0x0A)
                }
                try sink.write(data)
            } catch {
                failWriter()
                return
            }
        }
    }

    private func failWriter() {
        state.withLock { state in
            state.writerErrorCount &+= 1
            state.disabled = true
            state.drainScheduled = false
            state.pending.removeAll(keepingCapacity: false)
            state.pendingIndex = 0
        }
        closeSink()
    }

    private func closeSink() {
        do {
            try sink.close()
        } catch {
            state.withLock { state in
                state.writerErrorCount &+= 1
                state.disabled = true
            }
        }
    }

    private func recordStaticGraph(operation: SWBBuildSystem.BuildOperation) {
        var storedTasks: [String: any ExecutableTask] = [:]
        operation.buildDescription.taskStore.forEachTask { task in
            storedTasks[task.identifier.rawValue] = task
        }

        do {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: operation.buildDescription.manifestPath.str))
            guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let commands = root["commands"] as? [String: Any] else {
                throw AcceleratorTraceError.invalidManifest
            }

            var commandInputs: [String: [String]] = [:]
            var producerByNode: [String: String] = [:]
            for commandName in commands.keys.sorted() {
                guard let command = commands[commandName] as? [String: Any] else { continue }
                let inputs = Self.stringArray(command["inputs"])
                let outputs = Self.stringArray(command["outputs"])
                commandInputs[commandName] = inputs
                for output in outputs { producerByNode[output] = commandName }

                let identifier = TaskIdentifier(rawValue: commandName)
                if let task = storedTasks[commandName] {
                    declareTask(taskIdentifier: identifier, task: task, isDynamic: false, isSynthetic: false, inputNodes: inputs, outputNodes: outputs)
                } else {
                    declareSyntheticTask(identifier: identifier, command: command, inputNodes: inputs, outputNodes: outputs)
                }
            }

            for (consumer, inputs) in commandInputs.sorted(by: { $0.key < $1.key }) {
                for producer in Set(inputs.compactMap { producerByNode[$0] }).sorted() where producer != consumer {
                    emit(event: "task_dependency", payload: [
                        "task_id": .string(taskID(forRawKey: consumer)),
                        "depends_on_task_id": .string(taskID(forRawKey: producer)),
                        "edge_kind": .string("declared"),
                    ])
                }
            }

            for (identifier, task) in storedTasks where !isTaskDeclared(rawKey: identifier) {
                declareTask(taskIdentifier: TaskIdentifier(rawValue: identifier), task: task, isDynamic: false, isSynthetic: false, inputNodes: [], outputNodes: [])
            }
            emit(event: "trace_capability", payload: ["static_graph_complete": .boolean(true)])
        } catch {
            for (identifier, task) in storedTasks.sorted(by: { $0.key < $1.key }) {
                declareTask(taskIdentifier: TaskIdentifier(rawValue: identifier), task: task, isDynamic: false, isSynthetic: false, inputNodes: [], outputNodes: [])
            }
            state.withLock { $0.writerErrorCount &+= 1 }
            emit(event: "trace_warning", payload: [
                "kind": .string("manifest_unavailable"),
                "static_graph_complete": .boolean(false),
            ])
        }
    }

    private func ensureTaskDeclared(taskIdentifier: TaskIdentifier, task: any ExecutableTask, isDynamic: Bool) {
        guard !isTaskDeclared(rawKey: taskIdentifier.rawValue) else { return }
        declareTask(taskIdentifier: taskIdentifier, task: task, isDynamic: isDynamic, isSynthetic: false, inputNodes: [], outputNodes: [])
    }

    private func declareTask(
        taskIdentifier: TaskIdentifier,
        task: any ExecutableTask,
        isDynamic: Bool,
        isSynthetic: Bool,
        inputNodes: [String],
        outputNodes: [String]
    ) {
        guard markTaskDeclared(rawKey: taskIdentifier.rawValue) else { return }
        var payload: [String: AcceleratorTraceValue] = [
            "task_id": .string(taskID(for: taskIdentifier)),
            "action_family": .string(Self.actionFamily(ruleInfo: task.ruleInfo, tool: nil)),
            "target_id": task.forTarget.map { .string(targetID(for: $0)) } ?? .null,
            "is_dynamic": .boolean(isDynamic),
            "is_synthetic": .boolean(isSynthetic),
            "show_in_log": .boolean(task.showInLog),
            "priority": .string(Self.priorityName(task.priority)),
            "input_node_ids": .array(inputNodes.map { .string(nodeID(forRawKey: $0)) }),
            "output_node_ids": .array(outputNodes.map { .string(nodeID(forRawKey: $0)) }),
            "cache_eligibility": .string("unknown"),
            "exclusion_reason": .string("not_evaluated"),
        ]
        if configuration.privacyMode == .debug {
            payload["debug"] = .object([
                "task_identifier": .string(Self.truncate(taskIdentifier.rawValue)),
                "rule_info": .array(task.ruleInfo.map { .string(Self.truncate($0)) }),
            ])
        }
        emit(event: "task_declared", payload: payload)
    }

    private func declareSyntheticTask(
        identifier: TaskIdentifier,
        command: [String: Any],
        inputNodes: [String],
        outputNodes: [String]
    ) {
        guard markTaskDeclared(rawKey: identifier.rawValue) else { return }
        let tool = command["tool"] as? String
        var payload: [String: AcceleratorTraceValue] = [
            "task_id": .string(taskID(for: identifier)),
            "action_family": .string(Self.actionFamily(ruleInfo: [], tool: tool)),
            "target_id": .null,
            "is_dynamic": .boolean(false),
            "is_synthetic": .boolean(true),
            "show_in_log": .boolean(false),
            "priority": .string("unspecified"),
            "input_node_ids": .array(inputNodes.map { .string(nodeID(forRawKey: $0)) }),
            "output_node_ids": .array(outputNodes.map { .string(nodeID(forRawKey: $0)) }),
            "cache_eligibility": .string("unknown"),
            "exclusion_reason": .string("not_evaluated"),
        ]
        if configuration.privacyMode == .debug {
            payload["debug"] = .object(["command_identifier": .string(Self.truncate(identifier.rawValue))])
        }
        emit(event: "task_declared", payload: payload)
    }

    private func taskID(for identifier: TaskIdentifier) -> String {
        taskID(forRawKey: identifier.rawValue)
    }

    private func taskID(forRawKey rawKey: String) -> String {
        state.withLock { state in
            if let id = state.taskIDs[rawKey] { return id }
            let id = "t\(state.nextTaskID)"
            state.nextTaskID += 1
            state.taskIDs[rawKey] = id
            return id
        }
    }

    private func targetID(for target: ConfiguredTarget) -> String {
        let rawKey = target.guid.stringValue
        return state.withLock { state in
            if let id = state.targetIDs[rawKey] { return id }
            let id = "g\(state.nextTargetID)"
            state.nextTargetID += 1
            state.targetIDs[rawKey] = id
            return id
        }
    }

    private func nodeID(forRawKey rawKey: String) -> String {
        state.withLock { state in
            if let id = state.nodeIDs[rawKey] { return id }
            let id = "n\(state.nextNodeID)"
            state.nextNodeID += 1
            state.nodeIDs[rawKey] = id
            return id
        }
    }

    private func markTaskDeclared(rawKey: String) -> Bool {
        state.withLock { $0.declaredTasks.insert(rawKey).inserted }
    }

    private func isTaskDeclared(rawKey: String) -> Bool {
        state.withLock { $0.declaredTasks.contains(rawKey) }
    }

    private func elapsedNS() -> UInt64 {
        let now = clock()
        return now >= originNS ? now - originNS : 0
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func action(for parameters: BuildParameters) -> String {
        parameters.action == .build ? "build" : "other"
    }

    private static func configurationName(for parameters: BuildParameters) -> String {
        switch parameters.configuration?.lowercased() {
        case "debug": return "Debug"
        case "release": return "Release"
        default: return "other"
        }
    }

    private static func destination(for parameters: BuildParameters) -> String {
        guard let platform = parameters.activeRunDestination?.platform.lowercased() else { return "other" }
        return platform.contains("iphonesimulator") || platform.contains("iossimulator") ? "ios_simulator" : "other"
    }

    private static func architecture(for parameters: BuildParameters) -> String {
        let value = parameters.activeArchitecture ?? parameters.activeRunDestination?.targetArchitecture
        switch value {
        case "arm64": return "arm64"
        case "x86_64": return "x86_64"
        default: return "other"
        }
    }

    private static func actionFamily(ruleInfo: [String], tool: String?) -> String {
        let key = (ruleInfo.first ?? tool ?? "").lowercased()
        if key.contains("swift") && key.contains("module") { return "swift_emit_module" }
        if key.contains("swift") { return "swift_compile" }
        if key == "ld" || key.contains("link") { return "link" }
        if key.contains("assetcatalog") || key.contains("asset_compile") { return "asset_compile" }
        if key.contains("codesign") { return "codesign" }
        if key.contains("copy") { return "copy" }
        return "other"
    }

    private static func priorityName(_ priority: TaskPriority) -> String {
        switch priority {
        case .unspecified: return "unspecified"
        case .preferred: return "preferred"
        case .unblocksDownstreamTasks: return "unblocks_downstream"
        case .network: return "network"
        case .gate: return "gate"
        }
    }

    private static func statusName(_ status: BuildOperationEnded.Status) -> String {
        switch status {
        case .succeeded: return "succeeded"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    private static func statusName(_ status: BuildOperationTaskEnded.Status) -> String {
        switch status {
        case .succeeded: return "succeeded"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    private static func terminationKind(_ result: TaskResult?) -> String {
        guard case let .exit(exitStatus, _) = result else { return "unknown" }
        switch exitStatus {
        case .exit: return "exit"
        case .uncaughtSignal: return "signal"
        }
    }

    private static func microsecondsToNanoseconds(_ value: UInt64) -> UInt64 {
        value.multipliedReportingOverflow(by: 1_000).partialValue
    }

    private static func truncate(_ value: String) -> String {
        String(value.prefix(maximumDebugStringLength))
    }
}

private enum AcceleratorTraceError: Error {
    case invalidManifest
}

private extension Collection where Element == UInt8 {
    var asStableIdentityString: String {
        // This is never emitted. Decimal components with separators provide an
        // unambiguous dictionary key without lossy UTF-8 decoding.
        map(String.init).joined(separator: ",")
    }
}
