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

    @Test
    func disabledWithoutAnAbsoluteRoot() {
        #expect(SwiftCachedReplaySkip(environment: [:]) == nil)
        #expect(SwiftCachedReplaySkip(environment: [SwiftCachedReplaySkip.rootVariable: "relative"]) == nil)
    }
}

#endif
