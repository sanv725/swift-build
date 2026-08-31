//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT

import Foundation
import Testing

import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SwiftModuleArtifactReuseCoordinatorTests {
    @Test
    func exactGenerationReusesArtifacts() async throws {
        let fixture = try makeFixture()
        async let pendingDecision = fixture.coordinator.decision(
            moduleName: "Fixture",
            plannedOutputs: fixture.outputs,
            isCancelled: { false }
        )
        await _Concurrency.Task<Never, Never>.yield()
        #expect(fixture.coordinator.publishInterfaceFingerprint(
            "interface-v1",
            primaryPath: fixture.source,
            moduleName: "Fixture"
        ))

        let decision = await pendingDecision
        guard case .reuse(let outputCount, let outputBytes, _) = decision else {
            Issue.record("Expected exact artifact reuse, got \(decision)")
            return
        }
        #expect(outputCount == 2)
        #expect(outputBytes == 28)
    }

    @Test
    func interfaceMismatchFallsBackToApple() async throws {
        let fixture = try makeFixture()
        #expect(fixture.coordinator.publishInterfaceFingerprint(
            "interface-v2",
            primaryPath: fixture.source,
            moduleName: "Fixture"
        ))

        let decision = await fixture.coordinator.decision(
            moduleName: "Fixture",
            plannedOutputs: fixture.outputs,
            isCancelled: { false }
        )
        guard case .appleFallback(let reason, _) = decision else {
            Issue.record("Expected Apple fallback, got \(decision)")
            return
        }
        #expect(reason == "interface_fingerprint_mismatch")
    }

    @Test
    func staleSourceDigestFallsBackToApple() async throws {
        let fixture = try makeFixture()
        try localFS.write(
            fixture.source,
            contents: ByteString(encodingAsUTF8: "func value() -> Int { 2 }\n")
        )
        #expect(fixture.coordinator.publishInterfaceFingerprint(
            "interface-v1",
            primaryPath: fixture.source,
            moduleName: "Fixture"
        ))

        let decision = await fixture.coordinator.decision(
            moduleName: "Fixture",
            plannedOutputs: fixture.outputs,
            isCancelled: { false }
        )
        guard case .appleFallback(let reason, _) = decision else {
            Issue.record("Expected stale-source fallback, got \(decision)")
            return
        }
        #expect(reason == "artifact_validation_failed")
    }

    @Test
    func cancellationNeverFallsThroughToApple() async throws {
        let fixture = try makeFixture()
        let decision = await fixture.coordinator.decision(
            moduleName: "Fixture",
            plannedOutputs: fixture.outputs,
            isCancelled: { true }
        )
        guard case .cancelled = decision else {
            Issue.record("Expected cancellation, got \(decision)")
            return
        }
    }

    private struct Fixture {
        let directory: NamedTemporaryDirectory
        let coordinator: SwiftModuleArtifactReuseCoordinator
        let source: Path
        let outputs: [Path]
    }

    private func makeFixture() throws -> Fixture {
        let directory = try NamedTemporaryDirectory()
        let source = directory.path.join("Source.swift")
        let module = directory.path.join("Fixture.swiftmodule")
        let documentation = directory.path.join("Fixture.swiftdoc")
        let sourceBytes = ByteString(encodingAsUTF8: "func value() -> Int { 1 }\n")
        let moduleBytes = ByteString(encodingAsUTF8: "module-artifact")
        let documentationBytes = ByteString(encodingAsUTF8: "documentation")
        try localFS.write(source, contents: sourceBytes)
        try localFS.write(module, contents: moduleBytes)
        try localFS.write(documentation, contents: documentationBytes)

        let configuration = SwiftModuleArtifactReuseConfiguration(
            moduleName: "Fixture",
            changedSourcePath: source.str,
            candidateSourceSHA256: digest(sourceBytes),
            expectedInterfaceFingerprint: "interface-v1",
            emitModuleArtifacts: [
                .init(
                    path: module.str,
                    byteCount: Int64(moduleBytes.count),
                    sha256: digest(moduleBytes)
                ),
                .init(
                    path: documentation.str,
                    byteCount: Int64(documentationBytes.count),
                    sha256: digest(documentationBytes)
                ),
            ],
            waitTimeoutMilliseconds: 25
        )
        let configurationPath = directory.path.join("module-reuse.json")
        try localFS.write(
            configurationPath,
            contents: ByteString(try JSONEncoder().encode(configuration))
        )
        return Fixture(
            directory: directory,
            coordinator: try SwiftModuleArtifactReuseCoordinator(
                configurationPath: configurationPath,
                fs: localFS
            ),
            source: source,
            outputs: [module, documentation]
        )
    }

    private func digest(_ bytes: ByteString) -> String {
        let hash = SHA256Context()
        hash.add(bytes: bytes)
        return hash.signature.asString
    }
}

#endif
