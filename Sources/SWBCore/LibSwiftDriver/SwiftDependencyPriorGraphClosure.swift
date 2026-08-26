//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_JOB_CAS_EXPERIMENT

import SWBUtil

/// A conservative invalidation cone derived from fresh projections for only
/// the edited primaries and the complete fine-grained graph retained from the
/// prior successful module build.
///
/// Once a prior caller observes a changed provider key, the caller is affected.
/// Because its new interface is not known yet, every interface it previously
/// provided is conservatively treated as changed for the next reverse-dependency
/// wave. This can over-admit work, but it cannot omit a transitive prior caller.
public struct SwiftDependencyPriorGraphClosureResult: Sendable, Equatable {
    public let invalidationCone: SwiftDependencyInvalidationCone
    public let changedProviderKeys: [SwiftDependencyFingerprintProjection.Key]
}

/// A short-lived, compiler-derived admission envelope written before llbuild
/// dispatches frontend tasks. Unlike `SwiftDependencyModuleManifest`, this is
/// deliberately not a completed module state: it contains only the fresh
/// changed-source projections needed to derive a conservative prior-graph
/// closure. The coordinator replaces it with a complete module manifest after
/// every admitted frontend has produced its real projection.
public struct SwiftDependencyGraphAdmissionManifest: Codable, Sendable, Equatable {
    public static let schema = "swift-build-dependency-graph-admission-v1"

    public struct ChangedSource: Codable, Sendable, Equatable, Comparable {
        public let sourceIdentity: String
        public let projection: SwiftDependencyFingerprintProjection

        public init(
            sourceIdentity: String,
            projection: SwiftDependencyFingerprintProjection
        ) {
            self.sourceIdentity = sourceIdentity
            self.projection = projection
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.sourceIdentity < rhs.sourceIdentity
        }
    }

    public let schema: String
    public let previousDependencyIdentity: String
    public let moduleStructureIdentity: String
    public let affectedSources: [String]
    public let reusableSources: [String]
    public let changedSources: [ChangedSource]

    public init(
        previousManifest: SwiftDependencyModuleManifest,
        closure: SwiftDependencyPriorGraphClosureResult,
        changedProjections: [String: SwiftDependencyFingerprintProjection]
    ) throws {
        let expectedSources = Set(previousManifest.sources.map(\.sourceIdentity))
        let affected = Set(closure.invalidationCone.affectedSources)
        let reusable = Set(closure.invalidationCone.reusableSources)
        let changed = Set(changedProjections.keys)
        guard previousManifest.schema == SwiftDependencyModuleManifest.schema,
              !changed.isEmpty,
              changed.isSubset(of: affected),
              affected.isDisjoint(with: reusable),
              affected.union(reusable) == expectedSources,
              changedProjections.values.allSatisfy({
                  $0.schema == SwiftDependencyFingerprintProjection.schema
                    && $0.compilerVersion == previousManifest.compilerVersion
                    && $0.sourceFileInterfaceFingerprint != nil
              }) else {
            throw StubError.error(
                "Swift dependency graph admission requires a complete conservative closure."
            )
        }
        self.schema = Self.schema
        self.previousDependencyIdentity = previousManifest.dependencyIdentity
        self.moduleStructureIdentity = previousManifest.structureIdentity
        self.affectedSources = affected.sorted()
        self.reusableSources = reusable.sorted()
        self.changedSources = changedProjections.map {
            .init(sourceIdentity: $0.key, projection: $0.value)
        }.sorted()
    }
}

public enum SwiftDependencyPriorGraphClosure {
    public static func calculate(
        previousManifest: SwiftDependencyModuleManifest,
        changedProjections: [String: SwiftDependencyFingerprintProjection]
    ) throws -> SwiftDependencyPriorGraphClosureResult {
        let previousSources = previousManifest.sources.map(\.sourceIdentity)
        let expectedSources = Set(previousSources)
        let changedSources = Set(changedProjections.keys)
        guard previousManifest.schema == SwiftDependencyModuleManifest.schema,
              !changedSources.isEmpty,
              changedSources.isSubset(of: expectedSources),
              changedProjections.values.allSatisfy({
                  $0.schema == SwiftDependencyFingerprintProjection.schema
                    && $0.compilerVersion == previousManifest.compilerVersion
                    && $0.sourceFileInterfaceFingerprint != nil
              }) else {
            throw StubError.error(
                "Swift dependency prior-graph closure requires valid changed projections within a complete prior manifest."
            )
        }

        let previousBySource = Dictionary(
            uniqueKeysWithValues: previousManifest.sources.map {
                ($0.sourceIdentity, $0.projection)
            }
        )
        let previousProjections = previousSources.compactMap { previousBySource[$0] }
        let currentProjections = previousSources.compactMap { source in
            changedProjections[source] ?? previousBySource[source]
        }
        guard previousProjections.count == previousSources.count,
              currentProjections.count == previousSources.count,
              let previousProviders = SwiftDependencyFingerprintResolver
                .providerFingerprints(from: previousProjections),
              let currentProviders = SwiftDependencyFingerprintResolver
                .providerFingerprints(from: currentProjections) else {
            throw StubError.error(
                "Swift dependency prior-graph closure could not resolve provider identities."
            )
        }

        let allProviderKeys = Set(previousProviders.keys).union(currentProviders.keys)
        var frontier = Set(allProviderKeys.filter {
            previousProviders[$0] != currentProviders[$0]
        })
        let changedProviderKeys = frontier.sorted()
        var affected = changedSources

        while !frontier.isEmpty {
            var nextFrontier: Set<SwiftDependencyFingerprintProjection.Key> = []
            for source in previousSources where !affected.contains(source) {
                guard let projection = previousBySource[source],
                      !frontier.isDisjoint(with: projection.dependedInterfaces) else {
                    continue
                }
                affected.insert(source)
                nextFrontier.formUnion(projection.providedInterfaces.map(\.key))
            }
            frontier = nextFrontier
        }

        return .init(
            invalidationCone: .init(
                affectedSources: affected.sorted(),
                reusableSources: expectedSources.subtracting(affected).sorted()
            ),
            changedProviderKeys: changedProviderKeys
        )
    }
}

#endif
