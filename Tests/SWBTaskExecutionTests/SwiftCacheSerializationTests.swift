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

import Testing

import SWBCore
import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SwiftCacheSerializationTests {
    private let compilerLocation: LibSwiftDriver.CompilerLocation = .path(Path("/toolchain/usr/bin/swiftc"))
    private let casOptions = CASOptions(
        casPath: Path("/tmp/swift-cas"),
        pluginPath: nil,
        remoteServicePath: nil,
        enableDiagnosticRemarks: true,
        enableStrictCASErrors: false,
        enableDetachedKeyQueries: true,
        limitingStrategy: .maxSizeBytes(.megabytes(64))
    )
    private let policy = SwiftBuildAcceleratorCachePolicy(mode: .verify, eligibility: .eligible)

    @Test
    func swiftDriverPayloadRoundTripsAcceleratorPolicy() throws {
        let original = SwiftDriverPayload(
            uniqueID: "driver-id",
            compilerLocation: compilerLocation,
            moduleName: "Feature",
            outputPrefix: "Feature-normal-arm64",
            tempDirPath: Path("/tmp/objects"),
            explicitModulesTempDirPath: Path("/tmp/modules"),
            variant: "normal",
            architecture: "arm64",
            cohortArchitectures: ["arm64"],
            eagerCompilationEnabled: true,
            explicitModulesEnabled: true,
            commandLine: ["builtin-SwiftDriver", "--", "swiftc", "-c"],
            ruleInfo: ["SwiftDriver", "Feature"],
            isUsingWholeModuleOptimization: false,
            casOptions: casOptions,
            acceleratorCachePolicy: policy,
            reportRequiredTargetDependencies: .yes,
            linkerResponseFilePath: Path("/tmp/linker.args"),
            linkerResponseFileFormat: .llvmStyleEscaping,
            dependencyFilteringRootPath: Path("/SDK"),
            verifyScannerDependencies: true,
            scannerDiagnosticsOutputPath: Path("/tmp/scanner.dia"),
            diagnosticAttachmentInfo: nil
        )

        let decoded: SwiftDriverPayload = try roundTrip(original)
        #expect(decoded.uniqueID == original.uniqueID)
        #expect(decoded.compilerLocation == original.compilerLocation)
        #expect(decoded.moduleName == original.moduleName)
        #expect(decoded.outputPrefix == original.outputPrefix)
        #expect(decoded.tempDirPath == original.tempDirPath)
        #expect(decoded.explicitModulesTempDirPath == original.explicitModulesTempDirPath)
        #expect(decoded.variant == original.variant)
        #expect(decoded.architecture == original.architecture)
        #expect(decoded.cohortArchitectures == original.cohortArchitectures)
        #expect(decoded.eagerCompilationEnabled == original.eagerCompilationEnabled)
        #expect(decoded.explicitModulesEnabled == original.explicitModulesEnabled)
        #expect(decoded.commandLine == original.commandLine)
        #expect(decoded.ruleInfo == original.ruleInfo)
        #expect(decoded.isUsingWholeModuleOptimization == original.isUsingWholeModuleOptimization)
        #expect(decoded.casOptions == original.casOptions)
        #expect(decoded.acceleratorCachePolicy == policy)
        #expect(decoded.reportRequiredTargetDependencies == original.reportRequiredTargetDependencies)
        #expect(decoded.linkerResponseFilePath == original.linkerResponseFilePath)
        #expect(decoded.linkerResponseFileFormat == original.linkerResponseFileFormat)
        #expect(decoded.dependencyFilteringRootPath == original.dependencyFilteringRootPath)
        #expect(decoded.verifyScannerDependencies == original.verifyScannerDependencies)
        #expect(decoded.scannerDiagnosticsOutputPath == original.scannerDiagnosticsOutputPath)
        if case .some = decoded.diagnosticAttachmentInfo {
            Issue.record("nil diagnostic attachment unexpectedly became non-nil")
        }
    }

    @Test
    func expandedDynamicJobKeysRoundTripAcceleratorPolicy() throws {
        let targetKey = SwiftDriverJobTaskKey(
            identifier: "planned-build",
            variant: "normal",
            arch: "arm64",
            driverJobKey: .targetJob(7),
            driverJobSignature: "target-signature",
            isUsingWholeModuleOptimization: false,
            compilerLocation: compilerLocation,
            casOptions: casOptions,
            acceleratorCachePolicy: policy
        )
        let decodedTarget: SwiftDriverJobTaskKey = try roundTrip(targetKey)
        #expect(decodedTarget.identifier == targetKey.identifier)
        #expect(decodedTarget.variant == targetKey.variant)
        #expect(decodedTarget.arch == targetKey.arch)
        #expect(decodedTarget.driverJobKey == targetKey.driverJobKey)
        #expect(decodedTarget.driverJobSignature == targetKey.driverJobSignature)
        #expect(decodedTarget.isUsingWholeModuleOptimization == targetKey.isUsingWholeModuleOptimization)
        #expect(decodedTarget.compilerLocation == targetKey.compilerLocation)
        #expect(decodedTarget.casOptions == targetKey.casOptions)
        #expect(decodedTarget.acceleratorCachePolicy == policy)

        let dependencyKey = SwiftDriverExplicitDependencyJobTaskKey(
            arch: "arm64",
            driverJobKey: .explicitDependencyJob(3),
            driverJobSignature: "dependency-signature",
            compilerLocation: compilerLocation,
            casOptions: casOptions,
            acceleratorCachePolicy: .init(mode: .observe, eligibility: .excluded(.unsupportedOutput))
        )
        let decodedDependency: SwiftDriverExplicitDependencyJobTaskKey = try roundTrip(dependencyKey)
        #expect(decodedDependency.arch == dependencyKey.arch)
        #expect(decodedDependency.driverJobKey == dependencyKey.driverJobKey)
        #expect(decodedDependency.driverJobSignature == dependencyKey.driverJobSignature)
        #expect(decodedDependency.compilerLocation == dependencyKey.compilerLocation)
        #expect(decodedDependency.casOptions == dependencyKey.casOptions)
        #expect(decodedDependency.acceleratorCachePolicy == dependencyKey.acceleratorCachePolicy)
    }

    @Test
    func dynamicJobPayloadRoundTripsAcceleratorPolicy() throws {
        let original = SwiftDriverJobDynamicTaskPayload(
            serializedDiagnosticInfo: [
                .init(serializedDiagnosticsPath: Path("/tmp/Feature.dia"), sourceFilePath: Path("/src/Feature.swift")),
                .init(serializedDiagnosticsPath: Path("/tmp/Module.dia"), sourceFilePath: nil),
            ],
            isUsingWholeModuleOptimization: false,
            compilerLocation: compilerLocation,
            casOptions: casOptions,
            acceleratorCachePolicy: policy
        )

        let decoded: SwiftDriverJobDynamicTaskPayload = try roundTrip(original)
        #expect(decoded.serializedDiagnosticInfo.map(\.serializedDiagnosticsPath) == original.serializedDiagnosticInfo.map(\.serializedDiagnosticsPath))
        #expect(decoded.serializedDiagnosticInfo.map(\.sourceFilePath) == original.serializedDiagnosticInfo.map(\.sourceFilePath))
        #expect(decoded.isUsingWholeModuleOptimization == original.isUsingWholeModuleOptimization)
        #expect(decoded.compilerLocation == original.compilerLocation)
        #expect(decoded.casOptions == original.casOptions)
        #expect(decoded.acceleratorCachePolicy == policy)
    }

    private func roundTrip<Value: Serializable>(_ value: Value) throws -> Value {
        let serializer = MsgPackSerializer()
        serializer.serialize(value)
        let deserializer = MsgPackDeserializer(serializer.byteString)
        return try deserializer.deserialize()
    }
}
