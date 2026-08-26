//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT

public import SWBUtil

public struct SwiftDependencyModuleManifest: Codable, Sendable, Equatable {
    public static let schema = "swift-build-dependency-module-manifest-v1"

    public struct SourceEntry: Codable, Sendable, Equatable, Comparable {
        public let sourceIdentity: String
        public let projection: SwiftDependencyFingerprintProjection
        public let dependencyFingerprintDigests: [String]

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.sourceIdentity < rhs.sourceIdentity
        }
    }

    public let schema: String
    public let moduleName: String
    public let toolchainIdentity: String
    public let pathPolicyIdentity: String
    public let compilerVersion: String
    public let sources: [SourceEntry]
    public let structureIdentity: String
    public let dependencyIdentity: String

    public init(
        moduleName: String,
        toolchainIdentity: String,
        pathPolicyIdentity: String,
        expectedSourceIdentities: [String],
        projectionsBySource: [String: SwiftDependencyFingerprintProjection]
    ) throws {
        guard !moduleName.isEmpty, !toolchainIdentity.isEmpty, !pathPolicyIdentity.isEmpty else {
            throw StubError.error("Swift dependency manifest identities must be nonempty.")
        }
        let expectedSources = expectedSourceIdentities.sorted()
        guard Set(expectedSources).count == expectedSources.count,
              expectedSources.allSatisfy({ Path($0).isAbsolute }) else {
            throw StubError.error("Swift dependency manifest sources must be unique absolute virtual paths.")
        }
        guard projectionsBySource.keys.sorted() == expectedSources else {
            throw StubError.error("Swift dependency manifest projections do not exactly cover the planned source set.")
        }

        let projections = expectedSources.compactMap { projectionsBySource[$0] }
        let compilerVersions = Set(projections.map(\.compilerVersion))
        guard compilerVersions.count == 1, let compilerVersion = compilerVersions.first else {
            throw StubError.error("Swift dependency manifest projections must share one compiler version.")
        }
        guard projections.allSatisfy({ $0.sourceFileInterfaceFingerprint != nil }) else {
            throw StubError.error("Swift dependency manifest requires every source interface fingerprint.")
        }
        guard let providers = SwiftDependencyFingerprintResolver.providerFingerprints(
            from: projections
        ) else {
            throw StubError.error("Swift dependency manifest contains an invalid projection schema.")
        }

        let sources = expectedSources.map { sourceIdentity in
            let projection = projectionsBySource[sourceIdentity]!
            return SourceEntry(
                sourceIdentity: sourceIdentity,
                projection: projection,
                dependencyFingerprintDigests: SwiftDependencyFingerprintResolver.localIdentityDigests(
                    for: projection,
                    providers: providers
                )
            )
        }
        let structureIdentity = Self.digest(fields: [
            Self.schema,
            moduleName,
            toolchainIdentity,
            pathPolicyIdentity,
            compilerVersion,
            "sources-v1",
        ] + expectedSources)
        var dependencyFields = [
            "swift-build-dependency-module-state-v1",
            structureIdentity,
        ]
        for source in sources {
            dependencyFields += [
                source.sourceIdentity,
                source.projection.sourceFileInterfaceFingerprint!,
                "dependencies-v1",
            ] + source.dependencyFingerprintDigests
        }

        self.schema = Self.schema
        self.moduleName = moduleName
        self.toolchainIdentity = toolchainIdentity
        self.pathPolicyIdentity = pathPolicyIdentity
        self.compilerVersion = compilerVersion
        self.sources = sources
        self.structureIdentity = structureIdentity
        self.dependencyIdentity = Self.digest(fields: dependencyFields)
    }

    private static func digest(fields: [String]) -> String {
        let context = SHA256Context()
        for field in fields {
            let bytes = Array(field.utf8)
            context.add(number: UInt64(bytes.count))
            context.add(bytes: bytes)
        }
        return context.signature.asString
    }
}

public struct SwiftDependencyInvalidationCone: Codable, Sendable, Equatable {
    public let affectedSources: [String]
    public let reusableSources: [String]

    public init(affectedSources: [String], reusableSources: [String]) {
        self.affectedSources = affectedSources.sorted()
        self.reusableSources = reusableSources.sorted()
    }

    public static func compare(
        previous: SwiftDependencyModuleManifest,
        current: SwiftDependencyModuleManifest,
        changedSourceIdentities: Set<String>
    ) -> Self? {
        guard previous.schema == SwiftDependencyModuleManifest.schema,
              current.schema == SwiftDependencyModuleManifest.schema,
              previous.structureIdentity == current.structureIdentity else {
            return nil
        }
        let expectedSources = Set(current.sources.map(\.sourceIdentity))
        guard changedSourceIdentities.isSubset(of: expectedSources) else { return nil }
        let previousEntries = Dictionary(
            uniqueKeysWithValues: previous.sources.map { ($0.sourceIdentity, $0) }
        )

        var affected = changedSourceIdentities
        for entry in current.sources {
            guard let prior = previousEntries[entry.sourceIdentity] else { return nil }
            if prior.dependencyFingerprintDigests != entry.dependencyFingerprintDigests {
                affected.insert(entry.sourceIdentity)
            }
        }
        return .init(
            affectedSources: affected.sorted(),
            reusableSources: expectedSources.subtracting(affected).sorted()
        )
    }
}

#endif
