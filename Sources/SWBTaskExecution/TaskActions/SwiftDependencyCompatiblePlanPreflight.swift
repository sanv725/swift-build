//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT && SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT

import Foundation

package import SWBCore
package import SWBUtil

/// Reuses the content-independent topology of a prior SwiftDriver plan while
/// forcing fresh compiler dependency/API projections for the changed source
/// and every caller discovered by the fixed-point scheduler. This completes
/// before dynamic frontend tasks are admitted.
package enum SwiftDependencyCompatiblePlanPreflight {
    package struct Job: Sendable, Equatable {
        package let sourceIdentity: String
        package let commandLine: [String]
        package let dependencyOutputPath: Path
        package let outputPaths: [Path]
        package let workingDirectory: Path

        package init(
            sourceIdentity: String,
            commandLine: [String],
            dependencyOutputPath: Path,
            outputPaths: [Path] = [],
            workingDirectory: Path = Path("/")
        ) {
            self.sourceIdentity = sourceIdentity
            self.commandLine = commandLine
            self.dependencyOutputPath = dependencyOutputPath
            self.outputPaths = outputPaths
            self.workingDirectory = workingDirectory
        }
    }

    package struct Execution: Sendable, Equatable {
        package let sourceIdentity: String
        package let commandLine: [String]
        package let dependencyOutputPath: Path
    }

    package struct Result: Sendable, Equatable {
        package let fixedPoint: SwiftDependencyFixedPointResult
        package let executions: [Execution]
    }

    package static func run(
        previousManifest: SwiftDependencyModuleManifest,
        changedSourceIdentities: Set<String>,
        jobs: [Job],
        overlayPath: Path,
        compileProjection: (Job, [String]) throws -> SwiftDependencyFingerprintProjection
    ) throws -> Result {
        let expectedSources = previousManifest.sources.map(\.sourceIdentity)
        var jobsBySource: [String: Job] = [:]
        for job in jobs {
            guard jobsBySource.updateValue(job, forKey: job.sourceIdentity) == nil else {
                throw StubError.error(
                    "Swift dependency compatible plan contains a duplicate primary."
                )
            }
        }
        guard overlayPath.isAbsolute,
              jobs.count == jobsBySource.count,
              jobsBySource.keys.sorted() == expectedSources else {
            throw StubError.error(
                "Swift dependency compatible-plan preflight requires exact primary coverage."
            )
        }

        var scheduler = try SwiftDependencyInvalidationScheduler(
            previousManifest: previousManifest,
            expectedSourceIdentities: expectedSources,
            changedSourceIdentities: changedSourceIdentities
        )
        var executions: [Execution] = []
        while let sourceIdentity = scheduler.nextSourceIdentity {
            guard let job = jobsBySource[sourceIdentity] else {
                throw StubError.error(
                    "Swift dependency compatible plan is missing an affected primary."
                )
            }
            let commandLine = try patchedCommandLine(
                job.commandLine,
                sourceIdentity: sourceIdentity,
                overlayPath: overlayPath
            )
            let projection = try compileProjection(job, commandLine)
            try scheduler.recordCompiledProjection(
                projection,
                for: sourceIdentity
            )
            executions.append(.init(
                sourceIdentity: sourceIdentity,
                commandLine: commandLine,
                dependencyOutputPath: job.dependencyOutputPath
            ))
        }
        return .init(fixedPoint: try scheduler.result(), executions: executions)
    }

    package static func runLive(
        snapshot: SwiftDriverPlanCacheSnapshot,
        configuration: SwiftDependencyShadowConfiguration,
        environment: [String: String],
        fs: any FSProxy
    ) throws -> Result {
        guard let rawPreflightManifestPath = configuration.preflightManifestPath,
              configuration.changedSourceIdentities.count == 1 else {
            throw StubError.error(
                "Swift dependency compatible-plan preflight configuration is incomplete."
            )
        }
        let preflightManifestPath = Path(rawPreflightManifestPath)
        let previousManifestPath = Path(configuration.previousManifestPath)
        guard preflightManifestPath.isAbsolute, previousManifestPath.isAbsolute else {
            throw StubError.error("Swift dependency preflight paths must be absolute.")
        }
        let previousBytes = try fs.read(previousManifestPath)
        let previousManifest = try JSONDecoder().decode(
            SwiftDependencyModuleManifest.self,
            from: Data(previousBytes.bytes)
        )

        let jobs = try snapshot.plannedBuild.plannedTargetJobs.compactMap { planned -> Job? in
            let commandLine = planned.driverJob.commandLine.map(\.asString)
            let primaries = values(after: "-primary-file", in: commandLine)
            guard primaries.count == 1 else { return nil }
            let dependencies = values(
                after: "-emit-reference-dependencies-path",
                in: commandLine
            )
            guard dependencies.count == 1 else {
                throw StubError.error(
                    "Swift dependency compatible-plan primary lacks one dependency output."
                )
            }
            let dependencyPath = Path(dependencies[0])
            return .init(
                sourceIdentity: primaries[0],
                commandLine: commandLine,
                dependencyOutputPath: dependencyPath.isAbsolute
                    ? dependencyPath
                    : planned.workingDirectory.join(dependencyPath),
                outputPaths: planned.driverJob.outputs,
                workingDirectory: planned.workingDirectory
            )
        }

        let overlayPath = preflightManifestPath.dirname.join("prefix-map-vfsoverlay.json")
        var overlayMappings = Dictionary(
            uniqueKeysWithValues: configuration.pathMappings.map {
                ($0.virtualPrefix, $0.physicalPrefix)
            }
        )
        for (virtualPrefix, environmentKey) in [
            ("/^sdk", "SDKROOT"),
            ("/^xcode", "DEVELOPER_DIR"),
            ("/^src", "PROJECT_DIR"),
            ("/^derived", "PROJECT_TEMP_DIR"),
            ("/^built", "BUILT_PRODUCTS_DIR"),
            ("/^workspace", "WORKSPACE_DIR"),
        ] {
            if let physicalPrefix = environment[environmentKey],
               Path(physicalPrefix).isAbsolute {
                overlayMappings[virtualPrefix] = physicalPrefix
            }
        }
        if let executable = jobs.first?.commandLine.first {
            let toolchainURL = URL(fileURLWithPath: executable)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if toolchainURL.path.hasSuffix(".xctoolchain") {
                overlayMappings["/^toolchain"] = toolchainURL.path
            }
        }
        let overlay: [String: Any] = [
            "version": 0,
            "case-sensitive": "false",
            "redirecting-with": "fallthrough",
            "roots": overlayMappings.keys.sorted().map { virtualPrefix in
                [
                    "type": "directory-remap",
                    "name": virtualPrefix,
                    "external-contents": overlayMappings[virtualPrefix]!,
                ]
            },
        ]
        let overlayBytes = try JSONSerialization.data(
            withJSONObject: overlay,
            options: [.sortedKeys]
        )
        try fs.createDirectory(overlayPath.dirname, recursive: true)
        try fs.write(
            overlayPath,
            contents: ByteString(overlayBytes),
            atomically: true
        )

        var childEnvironment = environment
        SwiftJobCASConfiguration.removeControlVariables(from: &childEnvironment)
        SwiftDependencyShadowConfiguration.removeControlVariable(from: &childEnvironment)
        childEnvironment.removeValue(forKey: "SWIFT_BUILD_DRIVER_PLAN_CACHE_ROOT")
        childEnvironment.removeValue(forKey: "SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE")
        childEnvironment.removeValue(forKey: "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY")
        childEnvironment.removeValue(forKey: "SWIFT_BUILD_DRIVER_PLAN_COMPATIBILITY_MODE")
        childEnvironment.removeValue(forKey: "SWIFT_BUILD_DRIVER_PLAN_DEPENDENCY_MANIFEST")
        childEnvironment.removeValue(forKey: "SWIFT_BUILD_DRIVER_PLAN_INPUT_IDENTITY")

        let result = try run(
            previousManifest: previousManifest,
            changedSourceIdentities: Set(configuration.changedSourceIdentities),
            jobs: jobs,
            overlayPath: overlayPath
        ) { job, commandLine in
            for outputPath in job.outputPaths {
                try fs.createDirectory(outputPath.dirname, recursive: true)
            }
            try execute(
                commandLine: commandLine,
                workingDirectory: job.workingDirectory,
                environment: childEnvironment,
                logPath: preflightManifestPath.dirname.join(
                    "compile-\(job.sourceIdentity.split(separator: "/").last ?? "unknown").log"
                )
            )
            return try SwiftDependencyFingerprintProjection.read(
                from: job.dependencyOutputPath,
                sourceIdentity: job.sourceIdentity,
                pathMappings: configuration.pathMappings
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try fs.write(
            preflightManifestPath,
            contents: ByteString(try encoder.encode(result.fixedPoint.manifest)),
            atomically: true
        )
        return result
    }

    package static func patchedCommandLine(
        _ plannedCommandLine: [String],
        sourceIdentity: String,
        overlayPath: Path
    ) throws -> [String] {
        guard !plannedCommandLine.isEmpty, overlayPath.isAbsolute else {
            throw StubError.error("Swift dependency compatible-plan command is incomplete.")
        }
        let primaryValues = values(after: "-primary-file", in: plannedCommandLine)
        let dependencyValues = values(
            after: "-emit-reference-dependencies-path",
            in: plannedCommandLine
        )
        guard primaryValues == [sourceIdentity], dependencyValues.count == 1 else {
            throw StubError.error(
                "Swift dependency compatible-plan command does not uniquely identify its primary outputs."
            )
        }

        return try patchedAuxiliaryCommandLine(
            plannedCommandLine,
            overlayPath: overlayPath
        )
    }

    package static func patchedAuxiliaryCommandLine(
        _ plannedCommandLine: [String],
        overlayPath: Path
    ) throws -> [String] {
        guard !plannedCommandLine.isEmpty, overlayPath.isAbsolute else {
            throw StubError.error("Swift dependency compatible-plan command is incomplete.")
        }
        var commandLine: [String] = []
        var index = 0
        while index < plannedCommandLine.count {
            let argument = plannedCommandLine[index]
            if argument == "-cache-compile-job" {
                index += 1
                continue
            }
            if argument == "-vfsoverlay" {
                guard plannedCommandLine.indices.contains(index + 1) else {
                    throw StubError.error(
                        "Swift dependency compatible-plan command has an incomplete VFS overlay."
                    )
                }
                index += 2
                continue
            }
            commandLine.append(argument)
            index += 1
        }
        if !commandLine.contains("-module-import-from-cas") {
            commandLine.append("-module-import-from-cas")
        }
        commandLine.append(contentsOf: ["-vfsoverlay", overlayPath.str])
        return commandLine
    }

    private static func values(after option: String, in commandLine: [String]) -> [String] {
        commandLine.indices.compactMap { index in
            guard commandLine[index] == option,
                  commandLine.indices.contains(index + 1) else { return nil }
            return commandLine[index + 1]
        }
    }

    private static func execute(
        commandLine: [String],
        workingDirectory: Path,
        environment: [String: String],
        logPath: Path
    ) throws {
        guard let executable = commandLine.first,
              Path(executable).isAbsolute,
              FileManager.default.isExecutableFile(atPath: executable),
              workingDirectory.isAbsolute else {
            throw StubError.error(
                "Swift dependency compatible-plan frontend command is not executable."
            )
        }
        try FileManager.default.createDirectory(
            atPath: logPath.dirname.str,
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: logPath.str, contents: nil),
              let log = FileHandle(forWritingAtPath: logPath.str) else {
            throw StubError.error("Swift dependency preflight could not create its compiler log.")
        }
        defer { try? log.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(commandLine.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory.str)
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw StubError.error(
                "Swift dependency compatible-plan frontend failed with status \(process.terminationStatus); see \(logPath.str)."
            )
        }
    }
}

#endif
