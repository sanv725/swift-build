//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT && canImport(Darwin)

import Foundation
import Testing

import SWBUtil
@testable import SWBTaskExecution

@Suite
fileprivate struct SwiftCachedReplaySkipTests {
    private func fixture() throws -> (skip: SwiftCachedReplaySkip, outputs: [Path], directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replay-skip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputs = ["a.o", "a.swiftdeps"].map { directory.appendingPathComponent($0) }
        for output in outputs { try Data("object \(output.lastPathComponent)".utf8).write(to: output) }
        let skip = try #require(SwiftCachedReplaySkip(environment: [
            SwiftCachedReplaySkip.rootVariable: directory.appendingPathComponent("records").path,
        ]))
        return (skip, outputs.map { Path($0.path) }, directory)
    }

    @Test
    func untouchedOutputsReuseTheRecordedStreams() throws {
        let (skip, outputs, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = ["key-1", "key-2"]
        #expect(skip.reusable(cacheKeys: keys, outputs: outputs) == nil)
        skip.record(cacheKeys: keys, outputs: outputs, streams: .init(standardOutput: "out", standardError: "warning: w"))
        let streams = try #require(skip.reusable(cacheKeys: keys, outputs: outputs))
        #expect(streams.standardOutput == "out")
        #expect(streams.standardError == "warning: w")
    }

    @Test(arguments: ["rewritten", "touched", "deleted", "other-keys", "invalidated"])
    func anyChangeReplays(_ variant: String) throws {
        let (skip, outputs, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var keys = ["key-1"]
        skip.record(cacheKeys: keys, outputs: outputs, streams: .init(standardOutput: "", standardError: ""))
        let first = URL(fileURLWithPath: outputs[0].str)
        switch variant {
        case "rewritten":
            // Same size, new inode (an atomic replace by a real compile or a different key's replay).
            let staging = directory.appendingPathComponent("staging")
            try Data("object a.o".utf8).write(to: staging)
            _ = rename(staging.path, first.path)
        case "touched":
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: first.path)
        case "deleted":
            try FileManager.default.removeItem(at: first)
        case "other-keys":
            keys = ["key-2"]
        default:
            skip.invalidate(cacheKeys: keys, outputs: outputs)
        }
        #expect(skip.reusable(cacheKeys: keys, outputs: outputs) == nil)
    }

    @Test(arguments: ["kept", "edited", "object-rewritten", "object-deleted", "other-plan", "invalidated"])
    func primaryRecordsHoldOnlyForUnchangedContentAndObject(_ variant: String) throws {
        let (skip, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = ["A", "B"].map { directory.appendingPathComponent("\($0).swift") }
        let objects = ["A", "B"].map { directory.appendingPathComponent("\($0).o") }
        for (source, object) in zip(sources, objects) {
            try Data("let \(source.lastPathComponent.prefix(1)) = 1".utf8).write(to: source)
            try Data("object".utf8).write(to: object)
        }
        let command = ["swift-frontend", "-frontend", "-c", "-primary-file", sources[0].path, "-primary-file", sources[1].path,
                       "-o", objects[0].path, "-o", objects[1].path]
        let replay = ["SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE": "replay", "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY": "plan-1"]
        let keys = try #require(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command, environment: replay))
        #expect(!skip.primaryRetained(planKey: "plan-1", primary: sources[0].path, object: objects[0].path))
        skip.recordPrimaries(keys: keys, commandLine: command)
        var planKey = "plan-1"
        switch variant {
        case "edited":
            try Data("let A = 2".utf8).write(to: sources[0])
        case "object-rewritten":
            let staging = directory.appendingPathComponent("staging")
            try Data("object".utf8).write(to: staging)
            _ = rename(staging.path, objects[0].path)
        case "object-deleted":
            try FileManager.default.removeItem(at: objects[0])
        case "other-plan":
            planKey = "plan-2"
        case "invalidated":
            skip.invalidatePrimaries(keys: keys, commandLine: command)
        default:
            break
        }
        #expect(skip.primaryRetained(planKey: planKey, primary: sources[0].path, object: objects[0].path) == (variant == "kept"))
        // B is untouched in every variant except a plan change or invalidation.
        #expect(skip.primaryRetained(planKey: planKey, primary: sources[1].path, object: objects[1].path)
                == !["other-plan", "invalidated"].contains(variant))
        // A record names its object: another object path never matches.
        #expect(!skip.primaryRetained(planKey: "plan-1", primary: sources[1].path, object: objects[0].path))
        #expect(SwiftCachedReplaySkip.primaryObjects(commandLine: Array(command.dropLast(2))) == nil)
    }

    @Test
    func uncachedCompileKeysBindPlanCommandLineAndPrimaryContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retained-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("A.swift"), other = directory.appendingPathComponent("B.swift")
        try Data("let a = 1".utf8).write(to: primary)
        try Data("let b = 1".utf8).write(to: other)
        let replay = ["SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE": "replay", "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY": "plan-1"]
        let command = ["swift-frontend", "-c", other.path, "-primary-file", primary.path, "-o", "A.o"]
        let keys = try #require(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command, environment: replay))
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command, environment: replay) == keys)

        // A non-primary source does not take part: within one generation it can change only inside bodies.
        try Data("let b = 2".utf8).write(to: other)
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command, environment: replay) == keys)
        // Primary content, plan key and command line each change the keys.
        var plan2 = replay
        plan2["SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY"] = "plan-2"
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command, environment: plan2) != keys)
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command + ["-g"], environment: replay) != keys)
        try Data("let a = 2".utf8).write(to: primary)
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command, environment: replay) != keys)

        // Ineligible: not a replay, no plan key, no inline primary, file lists, response files, relative or missing primaries.
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command, environment: ["SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE": "record", "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY": "plan-1"]) == nil)
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command, environment: ["SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE": "replay"]) == nil)
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: ["swift-frontend", "-c", primary.path], environment: replay) == nil)
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command + ["-primary-filelist", "list"], environment: replay) == nil)
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: command + ["@args.resp"], environment: replay) == nil)
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: ["swift-frontend", "-primary-file", "A.swift"], environment: replay) == nil)
        #expect(SwiftCachedReplaySkip.uncachedCompileKeys(commandLine: ["swift-frontend", "-primary-file", directory.appendingPathComponent("missing.swift").path], environment: replay) == nil)
    }

    @Test
    func disabledWithoutAnAbsoluteRoot() {
        #expect(SwiftCachedReplaySkip(environment: [:]) == nil)
        #expect(SwiftCachedReplaySkip(environment: [SwiftCachedReplaySkip.rootVariable: "relative"]) == nil)
    }
}

#endif
