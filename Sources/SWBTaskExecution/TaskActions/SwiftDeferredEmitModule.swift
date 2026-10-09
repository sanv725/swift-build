//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT && canImport(Darwin)
import Darwin
import Foundation
import SWBUtil

/// Defers a missed emit-module job of one named module out of the request (SwiftBuildOptimizer C975).
///
/// On Reframe the main module's emit-module job takes about 93 s single-threaded after a structural
/// edit, and its outputs only feed the debug stab (`Ld -add_ast_path`) and module copies for test
/// targets. With the control variables set, a cache-missed emit-module job of that module whose
/// planned outputs all exist is not run: its exact frontend command is written to the queue directory
/// and the previous outputs stay in place. The caller runs the queued command after delivery, which
/// writes the outputs and populates the compile cache under the planned key. Cache hits never reach
/// this point.
struct SwiftDeferredEmitModule: Sendable {
    static let moduleVariable = "SWIFT_BUILD_DEFER_EMIT_MODULE_NAME"
    static let queueVariable = "SWIFT_BUILD_DEFER_EMIT_MODULE_QUEUE"
    static let schema = "swift-build-deferred-emit-module-v1"

    struct Record: Codable {
        let schema: String
        let moduleName: String
        let commandLine: [String]
        let environment: [String: String]
        let workingDirectory: String
        let outputs: [String]
        let cacheKeys: [String]
    }

    let moduleName: String
    let queue: Path

    init?(environment: [String: String]) {
        guard let name = environment[Self.moduleVariable], !name.isEmpty,
              let raw = environment[Self.queueVariable], !raw.isEmpty else { return nil }
        let queue = Path(raw)
        guard queue.isAbsolute else { return nil }
        self.moduleName = name
        self.queue = queue
    }

    static func removeControlVariables(from environment: inout [String: String]) {
        environment.removeValue(forKey: moduleVariable)
        environment.removeValue(forKey: queueVariable)
    }

    /// Writes the queue record and returns its path, or nil (run the job now) when any planned output
    /// is missing or the record cannot be written.
    func enqueue(commandLine: [String], environment: [String: String], workingDirectory: Path,
                 outputs: [Path], cacheKeys: [String]) -> Path? {
        for output in outputs {
            var info = Darwin.stat()
            guard output.str.withCString({ Darwin.lstat($0, &info) }) == 0,
                  UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else { return nil }
        }
        let record = Record(schema: Self.schema, moduleName: moduleName, commandLine: commandLine,
                            environment: environment, workingDirectory: workingDirectory.str,
                            outputs: outputs.map(\.str), cacheKeys: cacheKeys)
        let context = SHA256Context()
        for field in [Self.schema] + cacheKeys + ["--"] + outputs.map(\.str) {
            let bytes = Array(field.utf8)
            context.add(number: UInt64(bytes.count))
            context.add(bytes: bytes)
        }
        let path = queue.join(context.signature.asString + ".json")
        do {
            try FileManager.default.createDirectory(atPath: queue.str, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: URL(fileURLWithPath: path.str), options: .atomic)
        } catch {
            return nil
        }
        return path
    }
}
#endif
