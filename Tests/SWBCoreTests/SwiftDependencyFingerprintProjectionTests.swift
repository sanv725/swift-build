//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT

import Foundation
import Testing

import SWBCore
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct SwiftDependencyFingerprintProjectionTests {
    private struct CompiledState {
        let provider: SwiftDependencyFingerprintProjection
        let caller: SwiftDependencyFingerprintProjection
    }

    @Test
    func readsCompilerBinarySwiftDepsIntoDeterministicProjection() throws {
        let encoded = "REVQUwEIAAArAAAABwGywMhCKYzCK8gCKfyCKLDCK4zCKjwkQSuUAi2EAimEAi2EwsMmzMIr1IIsjEIp/IIppAIrlMIvkEIpwMIvnIIshAIsoMIvuMIrkEIpPESDKaSCK5xCKcgCLMhCKrgCLfyCK7wCKZTCw0aQQinAQim4AinMwi+8giv8AimUgimkgiukAi2kwiu4wi+4wiuQQik8QEUqkEIpuAItpIIppEIpyMIvuMIrkEIpACFgAAA2AAAAAmSAwCAwqIApIEMCNWoSBMQBFRAJCAYBsUAJAgAAAPIAAAAAU3dpZnQgdmVyc2lvbiA1LjMtZGV2IChMTFZNIGY1MTZhYzYwMmMsIFN3aWZ0IGMzOWYzMWZlYmQpAAAACA4AAG1haW4uc3dpZnRkZXBzAAAIAQAAYQAAAAUGAAJAAzAAZWM0NDNiYjk4MmMzYTA2YTQzM2JkZDQ3Yjg1ZWViYTIHAgAFDgACQAMwAABlYzQ0M2JiOTgyYzNhMDZhNDMzYmRkNDdiODVlZWJhMgUAAAQAAAAA"
        let bytes = try #require(Data(base64Encoded: encoded))
        let temporaryDirectory = try NamedTemporaryDirectory()
        let path = temporaryDirectory.path.join("main.swiftdeps")
        try localFS.write(path, contents: ByteString(Array(bytes)))

        let projection = try SwiftDependencyFingerprintProjection.read(from: path)

        #expect(projection.schema == SwiftDependencyFingerprintProjection.schema)
        #expect(projection.compilerVersion == "Swift version 5.3-dev (LLVM f516ac602c, Swift c39f31febd)")
        #expect(projection.sourceFileInterfaceFingerprint == "ec443bb982c3a06a433bdd47b85eeba2")
        #expect(projection.providedInterfaces.count == 1)
        #expect(projection.providedInterfaces[0].key.kind == "source file")
        #expect(projection.providedInterfaces[0].fingerprint == "ec443bb982c3a06a433bdd47b85eeba2")
        #expect(projection.dependedInterfaces == [
            .init(kind: "top-level", aspect: "interface", context: nil, name: "a")
        ])
    }

    @Test
    func resolvesUsesAndRejectsMissingOrConflictingProviders() throws {
        let key = SwiftDependencyFingerprintProjection.Key(
            kind: "top-level",
            aspect: "interface",
            context: nil,
            name: "callee"
        )
        let provider = SwiftDependencyFingerprintProjection(
            compilerVersion: "swift-test",
            sourceFileInterfaceFingerprint: "file-api-a",
            providedInterfaces: [.init(key: key, fingerprint: "callee-api-a")],
            dependedInterfaces: []
        )
        let caller = SwiftDependencyFingerprintProjection(
            compilerVersion: "swift-test",
            sourceFileInterfaceFingerprint: "caller-api",
            providedInterfaces: [],
            dependedInterfaces: [key, key]
        )
        let providers = try #require(
            SwiftDependencyFingerprintResolver.providerFingerprints(from: [provider])
        )

        #expect(SwiftDependencyFingerprintResolver.identityDigests(
            for: caller,
            providers: providers
        ) == ["9:top-level|9:interface|0:|6:callee=callee-api-a"])
        #expect(SwiftDependencyFingerprintResolver.identityDigests(
            for: caller,
            providers: [:]
        ) == nil)

        let conflicting = SwiftDependencyFingerprintProjection(
            compilerVersion: "swift-test",
            sourceFileInterfaceFingerprint: "file-api-b",
            providedInterfaces: [.init(key: key, fingerprint: "callee-api-b")],
            dependedInterfaces: []
        )
        #expect(SwiftDependencyFingerprintResolver.providerFingerprints(
            from: [provider, conflicting]
        ) == nil)
    }

    @Test
    func compilerFingerprintsKeepCallerIdentityForBodyEditsAndChangeItForAPIEdits() throws {
        let temporaryDirectory = try NamedTemporaryDirectory()
        let base = try compileState(
            root: temporaryDirectory.path.join("base"),
            providerSource: "public func callee(_ value: Int) -> Int { value + 1 }\n"
        )
        let body = try compileState(
            root: temporaryDirectory.path.join("body"),
            providerSource: "public func callee(_ value: Int) -> Int { value + 2 }\n"
        )
        let api = try compileState(
            root: temporaryDirectory.path.join("api"),
            providerSource: "public func callee(_ value: Int, scale: Int = 1) -> Int { value * scale + 2 }\n"
        )

        #expect(base.provider.sourceFileInterfaceFingerprint == body.provider.sourceFileInterfaceFingerprint)
        #expect(base.provider.sourceFileInterfaceFingerprint != api.provider.sourceFileInterfaceFingerprint)
        #expect(base.caller.dependedInterfaces == body.caller.dependedInterfaces)

        let baseProviders = try #require(
            SwiftDependencyFingerprintResolver.providerFingerprints(from: [base.provider, base.caller])
        )
        let bodyProviders = try #require(
            SwiftDependencyFingerprintResolver.providerFingerprints(from: [body.provider, body.caller])
        )
        let apiProviders = try #require(
            SwiftDependencyFingerprintResolver.providerFingerprints(from: [api.provider, api.caller])
        )
        let baseIdentity = SwiftDependencyFingerprintResolver.localIdentityDigests(
            for: base.caller,
            providers: baseProviders
        )
        let bodyIdentity = SwiftDependencyFingerprintResolver.localIdentityDigests(
            for: body.caller,
            providers: bodyProviders
        )
        let apiIdentity = SwiftDependencyFingerprintResolver.localIdentityDigests(
            for: api.caller,
            providers: apiProviders
        )

        #expect(!baseIdentity.isEmpty)
        #expect(baseIdentity == bodyIdentity)
        #expect(baseIdentity != apiIdentity)
    }

    private func compileState(root: Path, providerSource: String) throws -> CompiledState {
        try localFS.createDirectory(root, recursive: true)
        let provider = root.join("Provider.swift")
        let caller = root.join("Caller.swift")
        try localFS.write(provider, contents: ByteString(encodingAsUTF8: providerSource))
        try localFS.write(
            caller,
            contents: ByteString(encodingAsUTF8: "public func callSite(_ value: Int) -> Int { callee(value) }\n")
        )
        let providerDependencies = root.join("Provider.swiftdeps")
        let callerDependencies = root.join("Caller.swiftdeps")
        try compile(
            primary: provider,
            secondary: caller,
            dependencies: providerDependencies,
            object: root.join("Provider.o")
        )
        try compile(
            primary: caller,
            secondary: provider,
            dependencies: callerDependencies,
            object: root.join("Caller.o")
        )
        return .init(
            provider: try SwiftDependencyFingerprintProjection.read(from: providerDependencies),
            caller: try SwiftDependencyFingerprintProjection.read(from: callerDependencies)
        )
    }

    private func compile(primary: Path, secondary: Path, dependencies: Path, object: Path) throws {
        let sdkPath = try macOSSDKPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "--sdk", "macosx",
            "swift-frontend",
            "-c",
            "-primary-file", primary.str,
            secondary.str,
            "-module-name", "DependencyFingerprintFixture",
            "-sdk", sdkPath,
            "-emit-reference-dependencies-path", dependencies.str,
            "-o", object.str,
        ]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unknown swift-frontend failure"
            throw StubError.error(message)
        }
    }

    private func macOSSDKPath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unable to resolve macOS SDK"
            throw StubError.error(message)
        }
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else {
            throw StubError.error("xcrun returned an empty macOS SDK path")
        }
        return output
    }
}

#endif
