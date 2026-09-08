//===----------------------------------------------------------------------===//
// This source file is part of the Swift open source project
// Licensed under Apache License v2.0 with Runtime Library Exception
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import TSCBasic
import SWBCore
import SWBUtil

@Suite
struct SwiftDriverDebuggerSearchPathTests {
    private let enabled = ["swiftc", "-cache-compile-job", "-explicit-module-build", "-Xfrontend", "-serialize-debugging-options"]

    private func preserve(_ args: [String]) throws -> [String] {
        try LibSwiftDriver.preservingDebuggerSearchPaths(args, diagnosticsEngine: TSCBasic.DiagnosticsEngine(handlers: []))
    }

    #if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT
    @Test
    func preservesExactSpellingJoinedPathsAndSearchOrder() throws {
        let input = enabled + ["-I", "/tmp/A path", "-F/private/tmp/B", "-I../relative", "-Isystem", "/system/imports", "-Fsystem", "/system/frameworks", "--", "input.swift"]
        let expected = ["swiftc", "-Xfrontend", "-I", "-Xfrontend", "/tmp/A path", "-Xfrontend", "-F", "-Xfrontend", "/private/tmp/B", "-Xfrontend", "-I", "-Xfrontend", "../relative", "-Xfrontend", "-Isystem", "-Xfrontend", "/system/imports", "-Xfrontend", "-Fsystem", "-Xfrontend", "/system/frameworks"] + Array(input.dropFirst())
        #expect(try preserve(input) == expected)
    }

    @Test
    func leavesClangAndAlreadyForwardedPathsAlone() throws {
        let input = enabled + ["-Xcc", "-I/clang", "-Xfrontend", "-I", "-Xfrontend", "/frontend"]
        #expect(try preserve(input) == input)
    }

    @Test
    func requiresCachingExplicitImportsAndSerializedDebugOptions() throws {
        let paths = ["-I", "/tmp/module"]
        let inputs = [
            ["swiftc", "-explicit-module-build", "-Xfrontend", "-serialize-debugging-options"],
            ["swiftc", "-cache-compile-job", "-Xfrontend", "-serialize-debugging-options"],
            ["swiftc", "-cache-compile-job", "-explicit-module-build"],
        ]
        for input in inputs {
            #expect(try preserve(input + paths) == input + paths)
        }
    }

    @Test
    func readsResponseFileOptionsWithoutReplacingTheResponseFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-debug-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let response = root.appendingPathComponent("flags.rsp")
        try "-cache-compile-job -explicit-module-build -Xfrontend -serialize-debugging-options -I \"/tmp/response path\"".write(to: response, atomically: true, encoding: .utf8)
        let input = ["swiftc", "@" + response.path, "input.swift"]
        #expect(try preserve(input) == ["swiftc", "-Xfrontend", "-I", "-Xfrontend", "/tmp/response path"] + Array(input.dropFirst()))
    }
    #else
    @Test
    func nonExperimentalBuildLeavesArgumentsUnchanged() throws {
        let input = enabled + ["-I", "/tmp/module"]
        #expect(try preserve(input) == input)
    }
    #endif

    #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
    @Test
    func rejectsPlansCreatedBeforeSearchPathPreservation() throws {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(6) {
            serializer.serialize(1)
            for _ in 0..<5 { serializer.serialize(0) }
        }
        do {
            let _: SwiftDriverPlanCacheSnapshot = try MsgPackDeserializer(serializer.byteString).deserialize()
            Issue.record("Accepted a cached plan that omitted debugger paths")
        } catch {
            #expect(String(describing: error).contains("Unsupported Swift Driver plan cache schema 1"))
        }
    }
    #endif
}
