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

/// Skips re-materializing a compile-cache hit whose outputs are untouched since the last replay of the
/// same cache keys (SwiftBuildOptimizer C964).
///
/// Stock replay rewrites every output of every cache-hit job and byte-compares it with the file on disk
/// (`OnDiskOutputFile::keep`); on Reframe that is about 4,400 jobs and 43 thread-seconds per edit, all
/// producing identical bytes. After a successful replay this records, per job, the cache keys, each
/// output's device, inode, size and nanosecond mtime, and the replayed stdout/stderr. A later replay of
/// the same keys whose outputs all still match re-emits the recorded streams instead of replaying.
/// Any difference, missing file or unreadable record replays as before. Cache-key lookup and the
/// materialization check still run first, so a lost CAS entry is still a miss.
struct SwiftCachedReplaySkip: Sendable {
    static let rootVariable = "SWIFT_BUILD_CACHED_REPLAY_SKIP_ROOT"
    static let schema = "swift-build-cached-replay-skip-v1"

    struct OutputIdentity: Codable, Equatable {
        let path: String
        let device: Int64
        let inode: UInt64
        let size: Int64
        let mtimeNS: Int64
    }

    struct Record: Codable {
        let schema: String
        let cacheKeys: [String]
        let outputs: [OutputIdentity]
        let standardOutput: String
        let standardError: String
    }

    struct Streams: Sendable {
        let standardOutput: String
        let standardError: String
    }

    let root: Path

    init?(environment: [String: String]) {
        guard let raw = environment[Self.rootVariable], !raw.isEmpty else { return nil }
        let root = Path(raw)
        guard root.isAbsolute else { return nil }
        self.root = root
    }

    static func identity(_ path: Path) -> OutputIdentity? {
        var info = Darwin.stat()
        guard path.str.withCString({ Darwin.lstat($0, &info) }) == 0,
              UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else { return nil }
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return OutputIdentity(path: path.str, device: Int64(info.st_dev), inode: UInt64(info.st_ino),
                              size: Int64(info.st_size), mtimeNS: mtime)
    }

    func recordURL(cacheKeys: [String], outputs: [Path]) -> URL {
        let context = SHA256Context()
        for field in [Self.schema] + cacheKeys + ["--"] + outputs.map(\.str) {
            let bytes = Array(field.utf8)
            context.add(number: UInt64(bytes.count))
            context.add(bytes: bytes)
        }
        return URL(fileURLWithPath: root.join(context.signature.asString + ".json").str)
    }

    /// The recorded streams when every output still has the identity recorded after the last replay.
    func reusable(cacheKeys: [String], outputs: [Path]) -> Streams? {
        guard !cacheKeys.isEmpty, !outputs.isEmpty,
              let data = try? Data(contentsOf: recordURL(cacheKeys: cacheKeys, outputs: outputs)),
              data.count <= 16 * 1024 * 1024,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == Self.schema, record.cacheKeys == cacheKeys,
              record.outputs.map(\.path) == outputs.map(\.str) else { return nil }
        for (expected, path) in zip(record.outputs, outputs) {
            guard Self.identity(path) == expected else { return nil }
        }
        return Streams(standardOutput: record.standardOutput, standardError: record.standardError)
    }

    /// Records the outputs just materialized by a successful replay. Failures only cost a later replay.
    func record(cacheKeys: [String], outputs: [Path], streams: Streams) {
        guard !cacheKeys.isEmpty, !outputs.isEmpty else { return }
        var identities: [OutputIdentity] = []
        for path in outputs {
            guard let identity = Self.identity(path) else { return }
            identities.append(identity)
        }
        let record = Record(schema: Self.schema, cacheKeys: cacheKeys, outputs: identities,
                            standardOutput: streams.standardOutput, standardError: streams.standardError)
        guard let data = try? JSONEncoder().encode(record) else { return }
        let url = recordURL(cacheKeys: cacheKeys, outputs: outputs)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: staging)
            guard rename(staging.path, url.path) == 0 else { throw POSIXError(.EIO) }
        } catch {
            try? FileManager.default.removeItem(at: staging)
        }
    }

    /// Forgets a job's record before replay so an interrupted replay never leaves a stale match.
    func invalidate(cacheKeys: [String], outputs: [Path]) {
        _ = unlink(recordURL(cacheKeys: cacheKeys, outputs: outputs).path)
    }
}
#endif

/// Carries the optional skip into stock replay and reports whether it was used.
final class SwiftCachedReplaySkipHandle: @unchecked Sendable {
    #if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT && canImport(Darwin)
    let value: SwiftCachedReplaySkip?
    init(value: SwiftCachedReplaySkip?) { self.value = value }
    #endif
    var reused = false
}
