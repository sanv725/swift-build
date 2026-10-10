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

    /// Keys for a compile job that plan replay invalidated (SwiftBuildOptimizer C978). A file stays in the
    /// cumulative edit set until the next recording, so every replay invalidates its job again although
    /// the file may be unchanged since its last compile. These keys bind the plan key (one generation),
    /// the full command line and each primary's content, so `reusable` keeps that compile's outputs only
    /// for byte-identical primaries under the same plan. Other sources can only have changed inside
    /// bodies within one generation, which no other file's outputs depend on (the replay premise).
    /// Nil when this is not a plan replay, or primaries come from a file list or response file.
    static func uncachedCompileKeys(commandLine: [String], environment: [String: String]) -> [String]? {
        guard environment["SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE"] == "replay",
              let planKey = environment["SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY"], !planKey.isEmpty,
              !commandLine.contains("-primary-filelist"),
              !commandLine.dropFirst().contains(where: { $0.hasPrefix("@") }) else { return nil }
        let command = SHA256Context()
        for argument in commandLine {
            let bytes = Array(argument.utf8)
            command.add(number: UInt64(bytes.count))
            command.add(bytes: bytes)
        }
        var keys = [uncachedSchema, planKey, command.signature.asString]
        for (index, argument) in commandLine.enumerated() where argument == "-primary-file" {
            guard index + 1 < commandLine.count, commandLine[index + 1].hasPrefix("/"),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: commandLine[index + 1])) else { return nil }
            let content = SHA256Context()
            content.add(bytes: data)
            keys += [commandLine[index + 1], content.signature.asString]
        }
        return keys.count > 3 ? keys : nil
    }

    static let uncachedSchema = "swift-build-retained-compile-v1"

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

    // MARK: Per-primary records (SwiftBuildOptimizer C990)
    //
    // The records above are per job, keyed by every primary's content, so a narrowed batch that keeps
    // an edited primary E and a stale edit-set primary S recompiles both. After each clean compile of an
    // invalidated job this also records, per primary, the plan key, the primary's content SHA-256 and its
    // `-o` object's identity. Narrowing then drops S when its record still matches (same validity argument
    // as batch narrowing: within one generation other sources change only inside bodies), and a job whose
    // every primary still matches keeps its outputs.

    static let primarySchema = "swift-build-retained-primary-v1"

    struct PrimaryRecord: Codable {
        let schema: String
        let planKey: String
        let primary: String
        let contentSHA256: String
        let object: OutputIdentity
    }

    /// Each `-primary-file` paired with its `-o` (same order), or nil when the counts differ.
    static func primaryObjects(commandLine: [String]) -> [(primary: String, object: String)]? {
        let primaries = commandLine.indices.filter { commandLine[$0] == "-primary-file" && $0 + 1 < commandLine.count }
        let objects = commandLine.indices.filter { commandLine[$0] == "-o" && $0 + 1 < commandLine.count }
        guard !primaries.isEmpty, primaries.count == objects.count else { return nil }
        return zip(primaries, objects).map { (commandLine[$0 + 1], commandLine[$1 + 1]) }
    }

    func primaryRecordURL(planKey: String, primary: String) -> URL {
        let context = SHA256Context()
        for field in [Self.primarySchema, planKey, primary] {
            let bytes = Array(field.utf8)
            context.add(number: UInt64(bytes.count))
            context.add(bytes: bytes)
        }
        return URL(fileURLWithPath: root.join("primaries").join(context.signature.asString + ".json").str)
    }

    static func contentDigest(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let content = SHA256Context()
        content.add(bytes: data)
        return content.signature.asString
    }

    /// True when `primary`'s last clean compile under `planKey` saw its current content and wrote the
    /// object that is still at `object`.
    func primaryRetained(planKey: String, primary: String, object: String) -> Bool {
        guard primary.hasPrefix("/"), object.hasPrefix("/"),
              let data = try? Data(contentsOf: primaryRecordURL(planKey: planKey, primary: primary)),
              data.count <= 64 * 1024,
              let record = try? JSONDecoder().decode(PrimaryRecord.self, from: data),
              record.schema == Self.primarySchema, record.planKey == planKey, record.primary == primary,
              record.object.path == object, Self.identity(Path(object)) == record.object,
              Self.contentDigest(primary) == record.contentSHA256 else { return false }
        return true
    }

    /// Forgets the primaries' records before a compile so an interrupted compile never leaves a stale match.
    func invalidatePrimaries(keys: [String], commandLine: [String]) {
        guard keys.count > 3, let pairs = Self.primaryObjects(commandLine: commandLine) else { return }
        for pair in pairs { _ = unlink(primaryRecordURL(planKey: keys[1], primary: pair.primary).path) }
    }

    /// Records each primary of a clean compile. `keys` are the `uncachedCompileKeys` that held before and
    /// after the compile (plan key, command digest, then each primary with its content digest).
    func recordPrimaries(keys: [String], commandLine: [String]) {
        guard keys.count > 3, keys[0] == Self.uncachedSchema, (keys.count - 3) % 2 == 0,
              let pairs = Self.primaryObjects(commandLine: commandLine), pairs.count == (keys.count - 3) / 2 else { return }
        for (offset, pair) in pairs.enumerated() {
            let index = 3 + 2 * offset
            guard keys[index] == pair.primary, pair.object.hasPrefix("/"),
                  let object = Self.identity(Path(pair.object)) else { continue }
            let record = PrimaryRecord(schema: Self.primarySchema, planKey: keys[1], primary: pair.primary,
                                       contentSHA256: keys[index + 1], object: object)
            guard let data = try? JSONEncoder().encode(record) else { continue }
            let url = primaryRecordURL(planKey: keys[1], primary: pair.primary)
            let staging = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: staging)
                guard rename(staging.path, url.path) == 0 else { throw POSIXError(.EIO) }
            } catch {
                try? FileManager.default.removeItem(at: staging)
            }
        }
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
