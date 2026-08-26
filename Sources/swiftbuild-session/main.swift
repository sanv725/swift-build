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
    let target: String
    let derivedData: String
    let service: String
    let developerDirectory: String
    let compilationCAS: String?

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
        target = try required("--target")
        derivedData = try required("--derived-data")
        service = try required("--service")
        developerDirectory = try values.removeValue(forKey: "--developer-dir")
            ?? Self.selectedDeveloperDirectory()
        compilationCAS = values.removeValue(forKey: "--compilation-cas")
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
    }
}

private final class PlanningDelegate: SWBPlanningOperationDelegate, Sendable {
    func provisioningTaskInputs(
        targetGUID: String,
        provisioningSourceData: SWBProvisioningTaskInputsSourceData
    ) async -> SWBProvisioningTaskInputs {
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
    private var configuredTarget: SWBConfiguredTarget
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
            try await createdSession.loadWorkspace(containerPath: options.project)
            try await createdSession.setSystemInfo(.default())
            try await createdSession.setUserInfo(.default)
            let matches = try await createdSession.workspaceInfo().targetInfos.filter {
                $0.targetName == options.target
            }
            guard matches.count == 1, let match = matches.first else {
                throw SessionClientError.invalid(
                    "expected one target named \(options.target), found \(matches.count)"
                )
            }
            self.options = options
            service = createdService
            session = createdSession
            configuredTarget = SWBConfiguredTarget(guid: match.guid, parameters: nil)
        } catch {
            try? await createdSession.close()
            await createdService.close()
            throw error
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
        try await session.loadWorkspace(containerPath: options.project)
        try await session.setSystemInfo(.default())
        try await session.setUserInfo(.default)
        let matches = try await session.workspaceInfo().targetInfos.filter {
            $0.targetName == options.target
        }
        guard matches.count == 1, let match = matches.first else {
            throw SessionClientError.invalid(
                "expected one target named \(options.target), found \(matches.count)"
            )
        }
        configuredTarget = SWBConfiguredTarget(guid: match.guid, parameters: nil)
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
        parameters.configurationName = "Debug"
        parameters.activeRunDestination = SWBRunDestinationInfo(
            platform: "iphonesimulator",
            sdk: "iphonesimulator",
            sdkVariant: "iphonesimulator",
            targetArchitecture: "arm64",
            supportedArchitectures: ["arm64"],
            disableOnlyActiveArch: false
        )
        var settings = SWBSettingsTable()
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
        request.configuredTargets = [configuredTarget]
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
        var reportedBuildDescriptionID: String?
        var diagnostics: [String] = []
        for await event in try await operation.start() {
            switch event {
            case .planningOperationStarted:
                planningOperations += 1
            case .taskStarted:
                taskStarts += 1
            case .reportBuildDescription(let info):
                reportedBuildDescriptionID = info.buildDescriptionID
            case .buildDiagnostic(let info):
                diagnostics.append(info.message)
            case .taskDiagnostic(let info):
                diagnostics.append(info.message)
            default:
                break
            }
        }
        guard operation.state == .succeeded else {
            let detail = diagnostics.suffix(20).joined(separator: "; ")
            throw SessionClientError.build(
                "build ended in state \(operation.state)"
                    + (detail.isEmpty ? "" : ": \(detail.prefix(4_000))")
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
        let product = buildRoot + "/Products/Debug-iphonesimulator/\(options.target).app"
        guard FileManager.default.fileExists(atPath: product) else {
            throw SessionClientError.build("expected app product is missing: \(product)")
        }
        return Response(
            outcome: "built",
            command: "build",
            durationNS: DispatchTime.now().uptimeNanoseconds - started,
            planningOperations: planningOperations,
            taskStarts: taskStarts,
            buildDescriptionID: retainedBuildDescriptionID,
            reusedBuildDescription: descriptionID != nil,
            productPath: product,
            message: nil
        )
    }
}

private func emit(_ response: Response) throws {
    let data = try JSONEncoder().encode(response)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
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
            let decoder = JSONDecoder()
            while let line = readLine() {
                do {
                    let request = try decoder.decode(Request.self, from: Data(line.utf8))
                    guard request.schema == protocolSchema else {
                        throw SessionClientError.invalid("incompatible request schema")
                    }
                    switch request.command {
                    case "build":
                        try emit(try await active.build(
                            reuseBuildDescription: request.reuseBuildDescription ?? true
                        ))
                    case "reload":
                        try emit(try await active.reload())
                    case "quit":
                        try emit(Response(
                            outcome: "closing",
                            command: "quit",
                            durationNS: nil,
                            planningOperations: nil,
                            taskStarts: nil,
                            buildDescriptionID: nil,
                            reusedBuildDescription: nil,
                            productPath: nil,
                            message: nil
                        ))
                        try await active.close()
                        return
                    default:
                        throw SessionClientError.invalid(
                            "unsupported command: \(request.command)"
                        )
                    }
                } catch {
                    try emit(Response(
                        outcome: "error",
                        command: "request",
                        durationNS: nil,
                        planningOperations: nil,
                        taskStarts: nil,
                        buildDescriptionID: nil,
                        reusedBuildDescription: nil,
                        productPath: nil,
                        message: "\(error)"
                    ))
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
