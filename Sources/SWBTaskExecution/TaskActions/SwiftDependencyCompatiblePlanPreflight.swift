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
        package let durationNS: UInt64
    }

    package struct Result: Sendable, Equatable {
        package let fixedPoint: SwiftDependencyFixedPointResult
        package let executions: [Execution]
        package let priorGraphClosure: SwiftDependencyPriorGraphClosureResult
        package let changedProjectionDurationNS: UInt64
        package let dependencyOnlyExecutions: [Execution]
        package let dependencyOnlyProjectionParity: Bool?
        package let dependencyOnlyProjectionComparison: ProjectionComparison?
        package let dependencyOnlyPriorGraphClosure: SwiftDependencyPriorGraphClosureResult?
        package let dependencyOnlyGraphClosureParity: Bool?
    }

    package struct ProjectionComparison: Sendable, Equatable {
        package let compilerVersion: Bool
        package let sourceFileInterfaceFingerprint: Bool
        package let providedInterfaces: Bool
        package let dependedInterfaces: Bool
        package let dependencyOnlyProvidedCount: Int
        package let fullProvidedCount: Int
        package let dependencyOnlyDependedCount: Int
        package let fullDependedCount: Int

        package var exact: Bool {
            compilerVersion && sourceFileInterfaceFingerprint
                && providedInterfaces && dependedInterfaces
        }

        package var closureRelevantExact: Bool {
            compilerVersion && sourceFileInterfaceFingerprint && providedInterfaces
        }
    }

    package static func run(
        previousManifest: SwiftDependencyModuleManifest,
        changedSourceIdentities: Set<String>,
        jobs: [Job],
        overlayPath: Path,
        compileDependencyOnlyProjection: ((Job, [String]) throws -> SwiftDependencyFingerprintProjection)? = nil,
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
        var changedProjections: [String: SwiftDependencyFingerprintProjection] = [:]
        var changedProjectionDurationNS: UInt64 = 0
        var dependencyOnlyProjections: [String: SwiftDependencyFingerprintProjection] = [:]
        var dependencyOnlyExecutions: [Execution] = []
        var priorGraphClosure: SwiftDependencyPriorGraphClosureResult?
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
            if changedSourceIdentities.contains(sourceIdentity),
               let compileDependencyOnlyProjection,
               dependencyOnlyProjections[sourceIdentity] == nil {
                let dependencyOnlyOutputPath = dependencyOnlyOutputPath(for: job)
                let dependencyOnlyCommandLine = try dependencyOnlyCommandLine(
                    commandLine,
                    dependencyOutputPath: dependencyOnlyOutputPath
                )
                let dependencyOnlyTimer = ElapsedTimer()
                dependencyOnlyProjections[sourceIdentity] = try compileDependencyOnlyProjection(
                    job,
                    dependencyOnlyCommandLine
                )
                dependencyOnlyExecutions.append(.init(
                    sourceIdentity: sourceIdentity,
                    commandLine: dependencyOnlyCommandLine,
                    dependencyOutputPath: dependencyOnlyOutputPath,
                    durationNS: dependencyOnlyTimer.elapsedTime().nanoseconds
                ))
            }
            let compileTimer = ElapsedTimer()
            let projection = try compileProjection(job, commandLine)
            let compileDurationNS = compileTimer.elapsedTime().nanoseconds
            if changedSourceIdentities.contains(sourceIdentity),
               changedProjections[sourceIdentity] == nil {
                changedProjections[sourceIdentity] = projection
                changedProjectionDurationNS += compileDurationNS
                if changedProjections.count == changedSourceIdentities.count {
                    priorGraphClosure = try SwiftDependencyPriorGraphClosure.calculate(
                        previousManifest: previousManifest,
                        changedProjections: changedProjections
                    )
                }
            }
            try scheduler.recordCompiledProjection(
                projection,
                for: sourceIdentity
            )
            executions.append(.init(
                sourceIdentity: sourceIdentity,
                commandLine: commandLine,
                dependencyOutputPath: job.dependencyOutputPath,
                durationNS: compileDurationNS
            ))
        }
        guard let priorGraphClosure else {
            throw StubError.error(
                "Swift dependency compatible plan did not produce every changed-source projection."
            )
        }
        let projectionComparisons = changedProjections.compactMap { source, full
            -> ProjectionComparison? in
            guard let dependencyOnly = dependencyOnlyProjections[source] else {
                return nil
            }
            return .init(
                compilerVersion: dependencyOnly.compilerVersion == full.compilerVersion,
                sourceFileInterfaceFingerprint:
                    dependencyOnly.sourceFileInterfaceFingerprint
                        == full.sourceFileInterfaceFingerprint,
                providedInterfaces:
                    dependencyOnly.providedInterfaces == full.providedInterfaces,
                dependedInterfaces:
                    dependencyOnly.dependedInterfaces == full.dependedInterfaces,
                dependencyOnlyProvidedCount: dependencyOnly.providedInterfaces.count,
                fullProvidedCount: full.providedInterfaces.count,
                dependencyOnlyDependedCount: dependencyOnly.dependedInterfaces.count,
                fullDependedCount: full.dependedInterfaces.count
            )
        }
        let projectionComparison = projectionComparisons.isEmpty
            ? nil
            : ProjectionComparison(
                compilerVersion: projectionComparisons.allSatisfy(\.compilerVersion),
                sourceFileInterfaceFingerprint: projectionComparisons.allSatisfy(
                    \.sourceFileInterfaceFingerprint
                ),
                providedInterfaces: projectionComparisons.allSatisfy(\.providedInterfaces),
                dependedInterfaces: projectionComparisons.allSatisfy(\.dependedInterfaces),
                dependencyOnlyProvidedCount: projectionComparisons.reduce(0) {
                    $0 + $1.dependencyOnlyProvidedCount
                },
                fullProvidedCount: projectionComparisons.reduce(0) {
                    $0 + $1.fullProvidedCount
                },
                dependencyOnlyDependedCount: projectionComparisons.reduce(0) {
                    $0 + $1.dependencyOnlyDependedCount
                },
                fullDependedCount: projectionComparisons.reduce(0) {
                    $0 + $1.fullDependedCount
                }
            )
        let dependencyOnlyPriorGraphClosure =
            dependencyOnlyProjections.count == changedSourceIdentities.count
                ? try? SwiftDependencyPriorGraphClosure.calculate(
                    previousManifest: previousManifest,
                    changedProjections: dependencyOnlyProjections
                )
                : nil
        return .init(
            fixedPoint: try scheduler.result(),
            executions: executions,
            priorGraphClosure: priorGraphClosure,
            changedProjectionDurationNS: changedProjectionDurationNS,
            dependencyOnlyExecutions: dependencyOnlyExecutions,
            dependencyOnlyProjectionParity: projectionComparison?.exact,
            dependencyOnlyProjectionComparison: projectionComparison,
            dependencyOnlyPriorGraphClosure: dependencyOnlyPriorGraphClosure,
            dependencyOnlyGraphClosureParity: dependencyOnlyPriorGraphClosure.map {
                $0 == priorGraphClosure
            }
        )
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
            overlayPath: overlayPath,
            compileDependencyOnlyProjection: { job, commandLine in
                let dependencyOutputPath = try dependencyOutputPath(in: commandLine)
                try fs.createDirectory(dependencyOutputPath.dirname, recursive: true)
                try execute(
                    commandLine: commandLine,
                    workingDirectory: job.workingDirectory,
                    environment: childEnvironment,
                    logPath: preflightManifestPath.dirname.join(
                        "dependency-only-\(job.sourceIdentity.split(separator: "/").last ?? "unknown").log"
                    )
                )
                return try SwiftDependencyFingerprintProjection.read(
                    from: dependencyOutputPath,
                    sourceIdentity: job.sourceIdentity,
                    pathMappings: configuration.pathMappings
                )
            },
            compileProjection: { job, commandLine in
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
        })
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

    package static func dependencyOnlyCommandLine(
        _ plannedCommandLine: [String],
        dependencyOutputPath: Path
    ) throws -> [String] {
        guard !plannedCommandLine.isEmpty, dependencyOutputPath.isAbsolute else {
            throw StubError.error(
                "Swift dependency-only projection command is incomplete."
            )
        }
        let pairedOutputs: Set<String> = [
            "-o",
            "-emit-dependencies-path",
            "-serialize-diagnostics-path",
            "-emit-const-values-path",
            "-emit-module-path",
            "-emit-module-doc-path",
            "-emit-module-source-info-path",
            "-emit-objc-header-path",
            "-emit-tbd-path",
            "-index-unit-output-path",
            "-save-optimization-record-path",
        ]
        let outputModes: Set<String> = [
            "-c", "-emit-object", "-emit-module", "-emit-objc-header",
            "-emit-tbd", "-serialize-diagnostics", "-emit-const-values",
        ]
        var commandLine: [String] = []
        var index = 0
        var replacedCompileMode = false
        while index < plannedCommandLine.count {
            let argument = plannedCommandLine[index]
            if argument == "-Xcc" || argument == "-Xfrontend" {
                guard plannedCommandLine.indices.contains(index + 1) else {
                    throw StubError.error(
                        "Swift dependency-only projection command has an incomplete forwarded argument."
                    )
                }
                commandLine.append(contentsOf: [argument, plannedCommandLine[index + 1]])
                index += 2
                continue
            }
            if argument == "-emit-reference-dependencies-path" {
                guard plannedCommandLine.indices.contains(index + 1) else {
                    throw StubError.error(
                        "Swift dependency-only projection command has an incomplete dependency output."
                    )
                }
                commandLine.append(contentsOf: [argument, dependencyOutputPath.str])
                index += 2
                continue
            }
            if pairedOutputs.contains(argument) {
                guard plannedCommandLine.indices.contains(index + 1) else {
                    throw StubError.error(
                        "Swift dependency-only projection command has an incomplete output option."
                    )
                }
                index += 2
                continue
            }
            if outputModes.contains(argument) {
                if argument == "-c" || argument == "-emit-object" {
                    replacedCompileMode = true
                }
                index += 1
                continue
            }
            commandLine.append(argument)
            index += 1
        }
        guard replacedCompileMode,
              values(after: "-emit-reference-dependencies-path", in: commandLine)
                == [dependencyOutputPath.str] else {
            throw StubError.error(
                "Swift dependency-only projection command lacks a unique compile mode or dependency output."
            )
        }
        commandLine.append("-typecheck")
        commandLine.append("-experimental-skip-all-function-bodies")
        return commandLine
    }

    private static func dependencyOnlyOutputPath(for job: Job) -> Path {
        job.dependencyOutputPath.dirname.join(
            ".\(job.dependencyOutputPath.basename).dependency-only"
        )
    }

    private static func dependencyOutputPath(in commandLine: [String]) throws -> Path {
        let values = values(after: "-emit-reference-dependencies-path", in: commandLine)
        guard values.count == 1, Path(values[0]).isAbsolute else {
            throw StubError.error(
                "Swift dependency-only projection output must be one absolute path."
            )
        }
        return Path(values[0])
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
