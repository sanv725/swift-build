import Foundation
import SwiftBuild
import Darwin

private let protocolSchema = "swiftbuild-session-v1"

private enum SessionClientError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)
    case build(String)

    var description: String {
        switch self {
        case .usage(let message), .invalid(let message), .build(let message):
            return message
        }
    }
}

private struct Options {
    let project: String
    /// Comma-separated target names: the scheme's build entries (built with implicit dependencies).
    let targets: [String]
    let configuration: String
    /// When set, the client dumps the PIF itself with this package checkout, as the stock row's
    /// `-clonedSourcePackagesDirPath` does; the service's own dump would resolve packages elsewhere.
    let clonedSourcePackages: String?
    /// Resident mode: serve JSON lines on this Unix socket, one connection at a time, instead of stdin.
    let socket: String?
    let idleExitSeconds: Int
    /// When set, each build appends one JSON line per started task (rule, signature, command line).
    let taskLog: String?
    let derivedData: String
    let service: String
    let developerDirectory: String
    let compilationCAS: String?
    /// Exact command-line build-setting overrides (a JSON object); replaces the built-in table.
    let settings: [String: String]?

    private static func selectedDeveloperDirectory() throws -> String {
        if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           !developerDirectory.isEmpty {
            return developerDirectory
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let selected = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !selected.isEmpty else {
            throw SessionClientError.invalid(
                "cannot determine active Xcode developer directory"
            )
        }
        return selected
    }

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--"), let value = iterator.next() else {
                throw SessionClientError.usage("expected --name value arguments")
            }
            guard values.updateValue(value, forKey: argument) == nil else {
                throw SessionClientError.usage("duplicate argument: \(argument)")
            }
        }
        func required(_ name: String) throws -> String {
            guard let value = values.removeValue(forKey: name), !value.isEmpty else {
                throw SessionClientError.usage("missing required argument: \(name)")
            }
            return value
        }
        project = try required("--project")
        targets = try required("--target").split(separator: ",").map(String.init)
        configuration = values.removeValue(forKey: "--configuration") ?? "Debug"
        clonedSourcePackages = values.removeValue(forKey: "--cloned-source-packages")
        socket = values.removeValue(forKey: "--socket")
        idleExitSeconds = Int(values.removeValue(forKey: "--idle-exit") ?? "900") ?? 900
        taskLog = values.removeValue(forKey: "--task-log")
        derivedData = try required("--derived-data")
        service = try required("--service")
        developerDirectory = try values.removeValue(forKey: "--developer-dir")
            ?? Self.selectedDeveloperDirectory()
        compilationCAS = values.removeValue(forKey: "--compilation-cas")
        if let path = values.removeValue(forKey: "--settings") {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            settings = try JSONDecoder().decode([String: String].self, from: data)
        } else {
            settings = nil
        }
        guard values.isEmpty else {
            throw SessionClientError.usage(
                "unsupported arguments: \(values.keys.sorted().joined(separator: ", "))"
            )
        }
    }
}

private struct Request: Decodable {
    let schema: String
    let command: String
    let reuseBuildDescription: Bool?

    enum CodingKeys: String, CodingKey {
        case schema
        case command
        case reuseBuildDescription = "reuse_build_description"
    }
}

private struct Response: Encodable {
    let schema = protocolSchema
    let outcome: String
    let command: String
    let durationNS: UInt64?
    let planningOperations: Int?
    let taskStarts: Int?
    let buildDescriptionID: String?
    let reusedBuildDescription: Bool?
    let productPath: String?
    let message: String?
    /// For a failed build: tasks that failed (compile errors) and the error diagnostics, located.
    var failedTasks: Int? = nil
    var errors: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case schema
        case outcome
        case command
        case durationNS = "duration_ns"
        case planningOperations = "planning_operations"
        case taskStarts = "task_starts"
        case buildDescriptionID = "build_description_id"
        case reusedBuildDescription = "reused_build_description"
        case productPath = "product_path"
        case message
        case failedTasks = "failed_tasks"
        case errors
    }
}

private final class PlanningDelegate: SWBPlanningOperationDelegate, Sendable {
    func provisioningTaskInputs(
        targetGUID: String,
        provisioningSourceData: SWBProvisioningTaskInputsSourceData
    ) async -> SWBProvisioningTaskInputs {
        // Signing answers come from the service's recorded stock answers (SWIFT_BUILD_PROVISIONING_REPLAY).
        SWBProvisioningTaskInputs()
    }

    func executeExternalTool(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> SWBExternalToolResult {
        .deferred
    }
}

private final class PersistentSession {
    private let options: Options
    private let service: SWBBuildService
    private let session: SWBBuildServiceSession
    private var configuredTargets: [SWBConfiguredTarget]
    private var retainedBuildDescriptionID: String?

    init(options: Options) async throws {
        guard setenv("SWBBUILDSERVICE_PATH", options.service, 1) == 0 else {
            throw SessionClientError.invalid("cannot select exact build service executable")
        }
        let createdService = try await SWBBuildService(
            connectionMode: .outOfProcess,
            variant: .normal,
            serviceBundleURL: nil
        )
        let (result, diagnostics) = await createdService.createSession(
            name: options.project,
            developerPath: options.developerDirectory,
            resourceSearchPaths: [],
            cachePath: options.derivedData + "/SwiftBuildSessionCache",
            inferiorProductsPath: nil,
            environment: nil
        )
        let createdSession: SWBBuildServiceSession
        do {
            createdSession = try result.get()
        } catch {
            await createdService.close()
            let detail = diagnostics.map(\.message).joined(separator: "; ")
            throw SessionClientError.invalid(
                "cannot create Swift Build session: \(error)\(detail.isEmpty ? "" : ": \(detail)")"
            )
        }
        do {
            configuredTargets = try await Self.loadWorkspace(createdSession, options: options)
            self.options = options
            service = createdService
            session = createdSession
        } catch {
            try? await createdSession.close()
            await createdService.close()
            throw error
        }
    }

    /// Load the workspace (dumping the PIF with the stock package checkout when given) and resolve
    /// each target name to exactly one target.
    private static func loadWorkspace(
        _ session: SWBBuildServiceSession,
        options: Options
    ) async throws -> [SWBConfiguredTarget] {
        if let packages = options.clonedSourcePackages {
            let pif = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftbuild-session-\(getpid())-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: pif) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: options.developerDirectory + "/usr/bin/xcodebuild")
            process.arguments = [
                "-dumpPIF", pif.path,
                options.project.hasSuffix(".xcodeproj") ? "-project" : "-workspace", options.project,
                "-clonedSourcePackagesDirPath", packages,
            ]
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let detail = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SessionClientError.invalid(
                    "cannot dump PIF: \(String(decoding: detail.prefix(4_000), as: UTF8.self))"
                )
            }
            try await session.loadWorkspace(containerPath: pif.path)
        } else {
            try await session.loadWorkspace(containerPath: options.project)
        }
        try await session.setSystemInfo(.default())
        try await session.setUserInfo(.default)
        let infos = try await session.workspaceInfo().targetInfos
        return try options.targets.map { name in
            let matches = infos.filter { $0.targetName == name }
            guard matches.count == 1, let match = matches.first else {
                throw SessionClientError.invalid("expected one target named \(name), found \(matches.count)")
            }
            return SWBConfiguredTarget(guid: match.guid, parameters: nil)
        }
    }

    func close() async throws {
        if let retainedBuildDescriptionID {
            await session.releaseBuildDescription(id: SWBBuildDescriptionID(retainedBuildDescriptionID))
        }
        try await session.close()
        await service.close()
    }

    func reload() async throws -> Response {
        if let retainedBuildDescriptionID {
            await session.releaseBuildDescription(id: SWBBuildDescriptionID(retainedBuildDescriptionID))
            self.retainedBuildDescriptionID = nil
        }
        let started = DispatchTime.now().uptimeNanoseconds
        configuredTargets = try await Self.loadWorkspace(session, options: options)
        return Response(
            outcome: "reloaded",
            command: "reload",
            durationNS: DispatchTime.now().uptimeNanoseconds - started,
            planningOperations: nil,
            taskStarts: nil,
            buildDescriptionID: nil,
            reusedBuildDescription: nil,
            productPath: nil,
            message: nil
        )
    }

    func build(reuseBuildDescription: Bool) async throws -> Response {
        var parameters = SWBBuildParameters()
        parameters.action = "build"
        parameters.configurationName = options.configuration
        parameters.activeRunDestination = SWBRunDestinationInfo(
            platform: "iphonesimulator",
            sdk: "iphonesimulator",
            sdkVariant: "iphonesimulator",
            targetArchitecture: "arm64",
            supportedArchitectures: ["arm64"],
            disableOnlyActiveArch: false
        )
        var settings = SWBSettingsTable()
        if let exact = options.settings {
            for (key, value) in exact.sorted(by: { $0.key < $1.key }) {
                settings.set(value: value, for: key)
            }
        } else {
            settings.set(value: "NO", for: "CODE_SIGNING_ALLOWED")
            settings.set(value: "arm64", for: "ARCHS")
            settings.set(value: "YES", for: "ONLY_ACTIVE_ARCH")
            settings.set(value: "NO", for: "SWIFT_ENABLE_BATCH_MODE")
            settings.set(value: "NO", for: "ENABLE_DEBUG_DYLIB")
            if let compilationCAS = options.compilationCAS {
                settings.set(value: "YES", for: "SWIFT_ENABLE_COMPILE_CACHE")
                settings.set(value: compilationCAS, for: "COMPILATION_CACHE_CAS_PATH")
                settings.set(value: "YES", for: "COMPILATION_CACHE_KEEP_CAS_DIRECTORY")
                settings.set(value: "10G", for: "COMPILATION_CACHE_LIMIT_SIZE")
            }
        }
        parameters.overrides.commandLine = settings
        var synthesizedSettings = SWBSettingsTable()
        synthesizedSettings.set(value: "build", for: "ACTION")
        synthesizedSettings.set(value: "NO", for: "ENABLE_PREVIEWS")
        synthesizedSettings.set(value: "YES", for: "ENABLE_XOJIT_PREVIEWS")
        parameters.overrides.synthesized = synthesizedSettings

        let buildRoot = options.derivedData + "/Build"
        let arena = SWBArenaInfo(
            derivedDataPath: options.derivedData,
            buildProductsPath: buildRoot + "/Products",
            buildIntermediatesPath: buildRoot + "/Intermediates.noindex",
            pchPath: buildRoot + "/Intermediates.noindex/PrecompiledHeaders",
            indexRegularBuildProductsPath: nil,
            indexRegularBuildIntermediatesPath: nil,
            indexPCHPath: options.derivedData + "/Index.noindex/PrecompiledHeaders",
            indexDataStoreFolderPath: options.derivedData + "/Index.noindex/DataStore",
            indexEnableDataStore: true
        )
        parameters.arenaInfo = arena

        var request = SWBBuildRequest()
        request.parameters = parameters
        request.configuredTargets = configuredTargets
        request.useParallelTargets = true
        request.useImplicitDependencies = true
        request.hideShellScriptEnvironment = false
        request.showNonLoggedProgress = true
        request.containerPath = options.project
        let descriptionID = reuseBuildDescription ? retainedBuildDescriptionID : nil
        request.buildDescriptionID = descriptionID

        let started = DispatchTime.now().uptimeNanoseconds
        let operation = try await session.createBuildOperation(
            request: request,
            delegate: PlanningDelegate(),
            retainBuildDescription: descriptionID == nil
        )
        var planningOperations = 0
        var taskStarts = 0
        var startedTasks = Data()
        defer {
            if let taskLog = options.taskLog, !startedTasks.isEmpty {
                if !FileManager.default.fileExists(atPath: taskLog) {
                    FileManager.default.createFile(atPath: taskLog, contents: nil)
                }
                if let handle = FileHandle(forWritingAtPath: taskLog) {
                    handle.seekToEndOfFile()
                    handle.write(startedTasks)
                    try? handle.close()
                }
            }
        }
        var reportedBuildDescriptionID: String?
        var diagnostics: [String] = []
        var failedTasks = 0
        var errors: [String] = []
        for await event in try await operation.start() {
            switch event {
            case .planningOperationStarted:
                planningOperations += 1
            case .taskStarted(let info):
                taskStarts += 1
                if options.taskLog != nil {
                    let entry: [String: String] = [
                        "rule": info.ruleInfo,
                        "signature": info.taskSignature,
                        "command": info.commandLineDisplayString ?? "",
                    ]
                    if var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
                        line.append(0x0A)
                        startedTasks.append(line)
                    }
                }
            case .reportBuildDescription(let info):
                reportedBuildDescriptionID = info.buildDescriptionID
            case .buildDiagnostic(let info):
                diagnostics.append(info.message)
            case .taskDiagnostic(let info):
                diagnostics.append(info.message)
            case .taskComplete(let info):
                if info.result == .failed { failedTasks += 1 }
            case .diagnostic(let info):
                if info.kind == .error, errors.count < 200 {
                    switch info.location {
                    case .path(let path, fileLocation: .textual(let line, let column)?):
                        errors.append("\(path):\(line):\(column ?? 0): error: \(info.message)")
                    case .path(let path, _):
                        errors.append("\(path): error: \(info.message)")
                    default:
                        errors.append("error: \(info.message)")
                    }
                }
            default:
                break
            }
        }
        guard operation.state == .succeeded else {
            let detail = diagnostics.suffix(20).joined(separator: "; ")
            return Response(
                outcome: "failed",
                command: "build",
                durationNS: DispatchTime.now().uptimeNanoseconds - started,
                planningOperations: planningOperations,
                taskStarts: taskStarts,
                buildDescriptionID: nil,
                reusedBuildDescription: nil,
                productPath: nil,
                message: "build ended in state \(operation.state)"
                    + (detail.isEmpty ? "" : ": \(detail.prefix(4_000))"),
                failedTasks: failedTasks,
                errors: errors
            )
        }
        if descriptionID == nil {
            guard let reportedBuildDescriptionID else {
                throw SessionClientError.build("build did not report a retained description")
            }
            if let retainedBuildDescriptionID {
                await session.releaseBuildDescription(id: SWBBuildDescriptionID(retainedBuildDescriptionID))
            }
            retainedBuildDescriptionID = reportedBuildDescriptionID
        } else if reportedBuildDescriptionID != descriptionID {
            throw SessionClientError.build("reused build reported a different description")
        }
        return Response(
            outcome: "built",
            command: "build",
            durationNS: DispatchTime.now().uptimeNanoseconds - started,
            planningOperations: planningOperations,
            taskStarts: taskStarts,
            buildDescriptionID: retainedBuildDescriptionID,
            reusedBuildDescription: descriptionID != nil,
            productPath: nil,
            message: nil
        )
    }
}

private func emit(_ response: Response) throws {
    let data = try JSONEncoder().encode(response)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func encodedLine(_ response: Response) throws -> Data {
    var data = try JSONEncoder().encode(response)
    data.append(0x0A)
    return data
}

private func errorResponse(_ command: String, _ error: any Error) -> Response {
    Response(
        outcome: "error",
        command: command,
        durationNS: nil,
        planningOperations: nil,
        taskStarts: nil,
        buildDescriptionID: nil,
        reusedBuildDescription: nil,
        productPath: nil,
        message: "\(error)"
    )
}

/// Handle one request line. Returns the response and whether the client asked to quit.
private func handle(_ line: String, _ active: PersistentSession) async -> (Response, Bool) {
    do {
        let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
        guard request.schema == protocolSchema else {
            throw SessionClientError.invalid("incompatible request schema")
        }
        switch request.command {
        case "build":
            return (try await active.build(reuseBuildDescription: request.reuseBuildDescription ?? false), false)
        case "reload":
            return (try await active.reload(), false)
        case "quit":
            return (Response(
                outcome: "closing",
                command: "quit",
                durationNS: nil,
                planningOperations: nil,
                taskStarts: nil,
                buildDescriptionID: nil,
                reusedBuildDescription: nil,
                productPath: nil,
                message: nil
            ), true)
        default:
            throw SessionClientError.invalid("unsupported command: \(request.command)")
        }
    } catch {
        return (errorResponse("request", error), false)
    }
}

/// Resident mode: accept one connection at a time on a Unix socket and exit after `idleSeconds`
/// without a connection. The socket exists only while the session is ready.
private func serve(socketPath: String, idleSeconds: Int, active: PersistentSession) async throws {
    let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw SessionClientError.invalid("cannot create socket") }
    defer { Darwin.close(listener) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw SessionClientError.invalid("socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: pathBytes)
        buffer[pathBytes.count] = 0
    }
    unlink(socketPath)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, chmod(socketPath, 0o600) == 0, Darwin.listen(listener, 4) == 0 else {
        throw SessionClientError.invalid("cannot listen on \(socketPath)")
    }
    defer { unlink(socketPath) }
    while true {
        var poll = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&poll, 1, Int32(min(idleSeconds, Int(Int32.max / 1000)) * 1000))
        if ready == 0 { return }
        if ready < 0 { if errno == EINTR { continue } else { return } }
        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { continue }
        let stream = FileHandle(fileDescriptor: connection, closeOnDealloc: true)
        var buffer = Data()
        var quit = false
        while !quit {
            let chunk = stream.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                let (response, wantsQuit) = await handle(line, active)
                try? stream.write(contentsOf: try encodedLine(response))
                if wantsQuit { quit = true; break }
            }
        }
        if quit { return }
    }
}

@main
private struct Main {
    static func main() async {
        var client: PersistentSession?
        do {
            let options = try Options(arguments: CommandLine.arguments)
            let active = try await PersistentSession(options: options)
            client = active
            try emit(Response(
                outcome: "ready",
                command: "ready",
                durationNS: nil,
                planningOperations: nil,
                taskStarts: nil,
                buildDescriptionID: nil,
                reusedBuildDescription: nil,
                productPath: nil,
                message: nil
            ))
            if let socketPath = options.socket {
                try await serve(socketPath: socketPath, idleSeconds: options.idleExitSeconds, active: active)
            } else {
                while let line = readLine() {
                    let (response, quit) = await handle(line, active)
                    try emit(response)
                    if quit { break }
                }
            }
            try await active.close()
        } catch {
            try? emit(Response(
                outcome: "error",
                command: "startup",
                durationNS: nil,
                planningOperations: nil,
                taskStarts: nil,
                buildDescriptionID: nil,
                reusedBuildDescription: nil,
                productPath: nil,
                message: "\(error)"
            ))
            if let client {
                try? await client.close()
            }
            Foundation.exit(1)
        }
    }
}
