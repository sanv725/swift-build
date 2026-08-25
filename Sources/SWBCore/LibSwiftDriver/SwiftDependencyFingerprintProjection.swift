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
@_spi(Testing) import SwiftDriver
import TSCBasic

public import SWBUtil

public struct SwiftDependencyPathMapping: Codable, Sendable, Equatable, Hashable {
    public let physicalPrefix: String
    public let virtualPrefix: String

    public init(physicalPrefix: String, virtualPrefix: String) {
        self.physicalPrefix = physicalPrefix
        self.virtualPrefix = virtualPrefix
    }

    public func map(_ value: String) -> String? {
        guard value == physicalPrefix || value.hasPrefix(physicalPrefix + "/") else {
            return nil
        }
        return virtualPrefix + value.dropFirst(physicalPrefix.count)
    }
}

/// A portable, deterministic projection of the fine-grained dependency nodes
/// emitted by the Swift frontend in one `.swiftdeps` file.
public struct SwiftDependencyFingerprintProjection: Codable, Sendable, Equatable {
    public static let schema = "swift-build-swiftdeps-projection-v1"

    public struct Key: Codable, Sendable, Hashable, Comparable {
        public let kind: String
        public let aspect: String
        public let context: String?
        public let name: String?

        public init(kind: String, aspect: String, context: String?, name: String?) {
            self.kind = kind
            self.aspect = aspect
            self.context = context
            self.name = name
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.canonicalString < rhs.canonicalString
        }

        public var canonicalString: String {
            [kind, aspect, context ?? "", name ?? ""]
                .map { "\($0.utf8.count):\($0)" }
                .joined(separator: "|")
        }
    }

    public struct Definition: Codable, Sendable, Hashable, Comparable {
        public let key: Key
        public let fingerprint: String?

        public init(key: Key, fingerprint: String?) {
            self.key = key
            self.fingerprint = fingerprint
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return (lhs.fingerprint ?? "") < (rhs.fingerprint ?? "")
        }
    }

    public let schema: String
    public let compilerVersion: String
    public let sourceFileInterfaceFingerprint: String?
    public let providedInterfaces: [Definition]
    public let dependedInterfaces: [Key]

    public init(
        compilerVersion: String,
        sourceFileInterfaceFingerprint: String?,
        providedInterfaces: [Definition],
        dependedInterfaces: [Key]
    ) {
        self.schema = Self.schema
        self.compilerVersion = compilerVersion
        self.sourceFileInterfaceFingerprint = sourceFileInterfaceFingerprint
        self.providedInterfaces = Array(Set(providedInterfaces)).sorted()
        self.dependedInterfaces = Array(Set(dependedInterfaces)).sorted()
    }

    public static func read(
        from path: Path,
        sourceIdentity: String? = nil,
        pathMappings: [SwiftDependencyPathMapping] = []
    ) throws -> Self {
        guard path.isAbsolute else {
            throw StubError.error("Swift dependency projection requires an absolute .swiftdeps path.")
        }
        let typedFile = TypedVirtualPath(
            file: try VirtualPath(path: path.str).intern(),
            type: .swiftDeps
        )
        return try MockIncrementalCompilationSynchronizer.withInternedStringTable { table in
            guard let graph = try SourceFileDependencyGraph(
                contentsOf: typedFile,
                on: localFileSystem,
                internedStringTable: table
            ) else {
                throw StubError.error("Swift dependency artifact contains no dependency graph.")
            }

            var definitions: [Definition] = []
            var uses: [Key] = []
            graph.forEachNode { node in
                guard node.key.aspect == .interface else { return }
                let kind = node.key.designator.kindName
                let rawName = node.key.designator.name?.lookup(in: table)
                let normalizedName: String?
                if kind == "source file", let sourceIdentity {
                    normalizedName = sourceIdentity
                } else if let rawName {
                    normalizedName = normalize(rawName, with: pathMappings)
                } else {
                    normalizedName = nil
                }
                let key = Key(
                    kind: kind,
                    aspect: "interface",
                    context: node.key.designator.context?.lookup(in: table),
                    name: normalizedName
                )
                switch node.definitionVsUse {
                case .definition:
                    definitions.append(.init(
                        key: key,
                        fingerprint: node.fingerprint?.lookup(in: table)
                    ))
                case .use:
                    uses.append(key)
                }
            }

            return .init(
                compilerVersion: graph.compilerVersionString,
                sourceFileInterfaceFingerprint: graph.sourceFileNodePair.interface
                    .fingerprint?.lookup(in: table),
                providedInterfaces: definitions,
                dependedInterfaces: uses
            )
        }
    }

    private static func normalize(
        _ value: String,
        with mappings: [SwiftDependencyPathMapping]
    ) -> String {
        for mapping in mappings.sorted(by: {
            $0.physicalPrefix.utf8.count > $1.physicalPrefix.utf8.count
        }) {
            if let mapped = mapping.map(value) { return mapped }
        }
        return value
    }
}

public enum SwiftDependencyFingerprintResolver {
    /// Builds the current definition-key to API-fingerprint map. Multiple
    /// providers of one lookup key are aggregated so changing any overload or
    /// extension provider invalidates users of that key.
    public static func providerFingerprints(
        from projections: [SwiftDependencyFingerprintProjection]
    ) -> [SwiftDependencyFingerprintProjection.Key: String]? {
        var buckets: [SwiftDependencyFingerprintProjection.Key: Set<String>] = [:]
        for projection in projections {
            guard projection.schema == SwiftDependencyFingerprintProjection.schema else { return nil }
            for definition in projection.providedInterfaces {
                guard let fingerprint = definition.fingerprint
                    ?? projection.sourceFileInterfaceFingerprint else { continue }
                buckets[definition.key, default: []].insert(fingerprint)
            }
        }
        return buckets.mapValues { fingerprints in
            let sorted = fingerprints.sorted()
            guard sorted.count > 1 else { return sorted[0] }
            let context = SHA256Context()
            for fingerprint in sorted {
                let bytes = Array(fingerprint.utf8)
                context.add(number: UInt64(bytes.count))
                context.add(bytes: bytes)
            }
            return "aggregate-v1:" + context.signature.asString
        }
    }

    /// Resolves every interface use to the current provider fingerprint and
    /// returns the sorted strings consumed by `SwiftJobCASIdentity`.
    public static func identityDigests(
        for projection: SwiftDependencyFingerprintProjection,
        providers: [SwiftDependencyFingerprintProjection.Key: String]
    ) -> [String]? {
        guard projection.schema == SwiftDependencyFingerprintProjection.schema else { return nil }
        var result: [String] = []
        result.reserveCapacity(projection.dependedInterfaces.count)
        for key in projection.dependedInterfaces {
            guard let fingerprint = providers[key] else { return nil }
            result.append("\(key.canonicalString)=\(fingerprint)")
        }
        return result.sorted()
    }

    /// Resolves only dependencies provided by the complete local-module
    /// projection set. Unmatched standard-library, SDK, and imported-module
    /// keys are already covered by the job's toolchain/module identity.
    public static func localIdentityDigests(
        for projection: SwiftDependencyFingerprintProjection,
        providers: [SwiftDependencyFingerprintProjection.Key: String]
    ) -> [String] {
        projection.dependedInterfaces.compactMap { key in
            providers[key].map { "\(key.canonicalString)=\($0)" }
        }.sorted()
    }
}

#endif
