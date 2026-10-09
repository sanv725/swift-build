//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
package import SWBUtil
#if canImport(Darwin)
import Darwin
#endif

/// Persistent, source-independent result of a skipped-driver absence proof for one immutable
/// cached plan (SwiftBuildOptimizer C972). It holds every path a proof source is compared with,
/// and every filesystem fact the proof consulted. Revalidation stats those facts and re-resolves
/// only paths whose entry or parent directory changed, instead of decoding the plan and
/// resolving all of its paths again.
///
/// Soundness rests on these facts holding at revalidation:
/// - a path that resolved to itself still does when no component changed `lstat` identity and
///   no parent changed its entries (mtime/ctime); otherwise the changed components re-resolve;
/// - a path that resolved elsewhere through one symlinked prefix (`/tmp`, a versioned SDK link)
///   still does when that prefix resolves as before and the target path resolves to itself;
/// - any other path that resolved elsewhere always re-resolves;
/// - a file list or response file keeps its content identity (device, inode, size, mtime, ctime);
/// - a plugin file still resolves to a regular file (always re-queried).
/// Identities are captured before each resolution or read, so a change racing certification
/// leaves the certificate stale, never wrong.
package struct SwiftDriverAbsenceCertificate: Serializable, Equatable, Sendable {
    package struct Identity: Serializable, Equatable, Sendable {
        package var device: Int64
        package var inode: UInt64
        package var mode: UInt64
        package var size: Int64
        package var modifiedNS: Int64
        package var changedNS: Int64

        package init(device: Int64, inode: UInt64, mode: UInt64, size: Int64, modifiedNS: Int64, changedNS: Int64) {
            self.device = device; self.inode = inode; self.mode = mode
            self.size = size; self.modifiedNS = modifiedNS; self.changedNS = changedNS
        }

        /// The directory entry a path component names.
        var entry: [Int64] { [device, Int64(bitPattern: inode), Int64(mode) & 0o170000] }
        /// A directory's entry set: adding, removing or renaming an entry updates both times.
        var entries: [Int64] { [modifiedNS, changedNS] }

        package func serialize<T: Serializer>(to serializer: T) {
            serializer.serializeAggregate(6) {
                serializer.serialize(device); serializer.serialize(inode); serializer.serialize(mode)
                serializer.serialize(size); serializer.serialize(modifiedNS); serializer.serialize(changedNS)
            }
        }

        package init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(6)
            device = try deserializer.deserialize(); inode = try deserializer.deserialize()
            mode = try deserializer.deserialize(); size = try deserializer.deserialize()
            modifiedNS = try deserializer.deserialize(); changedNS = try deserializer.deserialize()
        }
    }

    package enum Revalidation: Equatable {
        /// Valid; `refreshed` carries current identities when many changed but resolved the same.
        case valid(refreshed: SwiftDriverAbsenceCertificate?)
        case stale(String)
    }

    static let schemaVersion = 2
    /// Re-resolving a few paths per request costs less than rewriting the certificate.
    package static let refreshThreshold = 16
    package var plan: Identity
    package var workingDirectory: String
    /// Every canonical (or uncanonicalized index metadata) path a source is compared with.
    package var references: [String]
    /// Every prefix of every path that resolved to itself, with its `lstat` identity.
    package var prefixes: [String]
    package var prefixIdentities: [Identity]
    /// Symlinked prefixes through which recorded paths resolve to self-resolving paths.
    package var links: [String]
    package var linkResolutions: [String]
    /// Other paths that resolved elsewhere, with their resolutions.
    package var aliases: [String]
    package var aliasResolutions: [String]
    package var regularFiles: [String]
    package var texts: [String]
    package var textIdentities: [Identity]

    package func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(13) {
            serializer.serialize(Self.schemaVersion)
            serializer.serialize(plan); serializer.serialize(workingDirectory)
            serializer.serialize(references)
            serializer.serialize(prefixes); serializer.serialize(prefixIdentities)
            serializer.serialize(links); serializer.serialize(linkResolutions)
            serializer.serialize(aliases); serializer.serialize(aliasResolutions)
            serializer.serialize(regularFiles)
            serializer.serialize(texts); serializer.serialize(textIdentities)
        }
    }

    package init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(13)
        let schema: Int = try deserializer.deserialize()
        guard schema == Self.schemaVersion else { throw StubError.error("Unsupported absence certificate schema \(schema).") }
        plan = try deserializer.deserialize(); workingDirectory = try deserializer.deserialize()
        references = try deserializer.deserialize()
        prefixes = try deserializer.deserialize(); prefixIdentities = try deserializer.deserialize()
        links = try deserializer.deserialize(); linkResolutions = try deserializer.deserialize()
        aliases = try deserializer.deserialize(); aliasResolutions = try deserializer.deserialize()
        regularFiles = try deserializer.deserialize()
        texts = try deserializer.deserialize(); textIdentities = try deserializer.deserialize()
        guard prefixes.count == prefixIdentities.count, links.count == linkResolutions.count,
              aliases.count == aliasResolutions.count,
              texts.count == textIdentities.count else {
            throw StubError.error("Absence certificate is inconsistent.")
        }
    }

    package init(plan: Identity, workingDirectory: String, references: [String], prefixes: [String],
                 prefixIdentities: [Identity], links: [String], linkResolutions: [String],
                 aliases: [String], aliasResolutions: [String],
                 regularFiles: [String], texts: [String], textIdentities: [Identity]) {
        self.plan = plan; self.workingDirectory = workingDirectory; self.references = references
        self.prefixes = prefixes; self.prefixIdentities = prefixIdentities
        self.links = links; self.linkResolutions = linkResolutions
        self.aliases = aliases; self.aliasResolutions = aliasResolutions
        self.regularFiles = regularFiles; self.texts = texts; self.textIdentities = textIdentities
    }

    package static func parent(_ path: String) -> String? {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// `lstat` (`follow == false`) or `stat` identity; nil when the path does not exist.
    package static func identity(_ path: String, follow: Bool) -> Identity? {
        #if canImport(Darwin)
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &info, follow ? 0 : AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino), mode: UInt64(info.st_mode),
                        size: Int64(info.st_size),
                        modifiedNS: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                        changedNS: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec))
        #else
        return nil
        #endif
    }

    /// Checks every recorded fact. Identities are captured before any re-resolution.
    package func revalidated(lstat: (String) -> Identity?, stat: (String) -> Identity?,
                             resolve: (String) -> String?, isRegularFile: (String) -> Bool) -> Revalidation {
        for (path, recorded) in zip(texts, textIdentities) where stat(path) != recorded {
            return .stale("text")
        }
        var current: [String: Identity] = [:]
        current.reserveCapacity(prefixes.count)
        for path in prefixes {
            guard let identity = lstat(path) else { return .stale("prefix-missing") }
            current[path] = identity
        }
        let recordedByPath = Dictionary(zip(prefixes, prefixIdentities), uniquingKeysWith: { first, _ in first })
        var reresolved = 0
        for (path, recorded) in zip(prefixes, prefixIdentities) {
            var changed = current[path]!.entry != recorded.entry
            if let parent = Self.parent(path) {
                guard let parentRecorded = recordedByPath[parent] else { return .stale("prefix-parent") }
                changed = changed || current[parent]!.entries != parentRecorded.entries
            }
            if changed {
                guard resolve(path) == path else { return .stale("prefix-resolution") }
                reresolved += 1
            }
        }
        for (path, resolution) in zip(links, linkResolutions) where resolve(path) != resolution {
            return .stale("link-resolution")
        }
        for (path, resolution) in zip(aliases, aliasResolutions) where resolve(path) != resolution {
            return .stale("alias-resolution")
        }
        guard regularFiles.allSatisfy(isRegularFile) else { return .stale("regular-file") }
        guard reresolved > Self.refreshThreshold else { return .valid(refreshed: nil) }
        var copy = self
        copy.prefixIdentities = prefixes.map { current[$0]! }
        return .valid(refreshed: copy)
    }

    package func encoded() -> ByteString {
        let serializer = MsgPackSerializer()
        serializer.serialize(self)
        return serializer.byteString
    }

    package static func decode(_ bytes: ByteString) throws -> Self {
        try MsgPackDeserializer.deserialize(bytes)
    }

    /// Wraps the proof's filesystem queries while certifying, capturing identities before
    /// each resolution or read.
    package final class Recorder {
        private let lstat: (String) -> Identity?
        private let stat: (String) -> Identity?
        private let resolve: (String) -> String?
        private var resolutions: [String: String?] = [:]
        private var prefixIdentities: [String: Identity] = [:]
        private var selfResolving = Set<String>()
        private var regularFiles = Set<String>()
        private var texts: [String: Identity] = [:]
        private var incomplete = false

        package init(lstat: @escaping (String) -> Identity? = { SwiftDriverAbsenceCertificate.identity($0, follow: false) },
                     stat: @escaping (String) -> Identity? = { SwiftDriverAbsenceCertificate.identity($0, follow: true) },
                     resolve: @escaping (String) -> String?) {
            self.lstat = lstat; self.stat = stat; self.resolve = resolve
        }

        package func canonical(_ path: String) -> String? {
            if let cached = resolutions[path] { return cached }
            var prefix: String? = path
            while let current = prefix, prefixIdentities[current] == nil {
                guard let identity = lstat(current) else { break }
                prefixIdentities[current] = identity
                prefix = SwiftDriverAbsenceCertificate.parent(current)
            }
            let result = resolve(path)
            resolutions[path] = result
            if result == path { selfResolving.insert(path) }
            return result
        }

        package func isRegularFile(_ path: String, _ query: (String) -> Bool) -> Bool {
            let result = query(path)
            if result { regularFiles.insert(path) }
            return result
        }

        package func text<T>(_ path: String, _ read: (String) -> T?) -> T? {
            if texts[path] == nil {
                guard let identity = stat(path) else { incomplete = true; return read(path) }
                texts[path] = identity
            }
            return read(path)
        }

        /// Nil when a consulted fact could not be identified.
        package func certificate(plan: Identity, workingDirectory: String,
                                 references: Set<String>) -> SwiftDriverAbsenceCertificate? {
            guard !incomplete else { return nil }
            // Split each alias at its first symlinked prefix when the rest maps unchanged onto a
            // self-resolving path: revalidation then resolves the link once, not every alias.
            var links: [String: String] = [:]
            var aliases: [(String, String)] = []
            var prefixResolutions: [String: String?] = [:]
            for (path, result) in resolutions.sorted(by: { $0.key < $1.key }) {
                guard let result, result != path else { continue }
                var link: (String, String)?
                var prefixes: [String] = []
                var prefix: String? = path
                while let current = prefix, current != "/" { prefixes.append(current); prefix = SwiftDriverAbsenceCertificate.parent(current) }
                for prefix in prefixes.reversed() {
                    let resolved = prefixResolutions[prefix] ?? resolve(prefix)
                    prefixResolutions[prefix] = resolved
                    if resolved != prefix { link = resolved.map { (prefix, $0) }; break }
                }
                if let (prefix, target) = link,
                   result == target + path.dropFirst(prefix.count), canonical(result) == result {
                    links[prefix] = target
                } else {
                    aliases.append((path, result))
                }
            }
            var prefixes = Set<String>()
            for path in selfResolving {
                var prefix: String? = path
                while let current = prefix, prefixes.insert(current).inserted {
                    prefix = SwiftDriverAbsenceCertificate.parent(current)
                }
            }
            let ordered = prefixes.sorted()
            var identities: [Identity] = []
            for path in ordered {
                guard let identity = prefixIdentities[path] else { return nil }
                identities.append(identity)
            }
            let orderedLinks = links.sorted { $0.key < $1.key }
            let orderedTexts = texts.keys.sorted()
            return SwiftDriverAbsenceCertificate(
                plan: plan, workingDirectory: workingDirectory, references: references.sorted(),
                prefixes: ordered, prefixIdentities: identities,
                links: orderedLinks.map(\.key), linkResolutions: orderedLinks.map(\.value),
                aliases: aliases.map(\.0), aliasResolutions: aliases.map(\.1),
                regularFiles: regularFiles.sorted(), texts: orderedTexts,
                textIdentities: orderedTexts.map { texts[$0]! })
        }
    }
}
