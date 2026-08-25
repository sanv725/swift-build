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

public struct SwiftDependencyFixedPointResult: Sendable, Equatable {
    public let manifest: SwiftDependencyModuleManifest
    public let invalidationCone: SwiftDependencyInvalidationCone
    public let compilationCounts: [String: Int]
}

/// Incrementally updates a prior complete module manifest as frontend jobs
/// finish. A source is scheduled whenever its resolved local API dependencies
/// differ from the dependencies against which its last retained or newly
/// compiled output was produced. The process reaches a fixed point when the
/// pending set is empty.
public struct SwiftDependencyInvalidationScheduler: Sendable {
    private let previousManifest: SwiftDependencyModuleManifest
    private let previousEntries: [String: SwiftDependencyModuleManifest.SourceEntry]
    private var projectionsBySource: [String: SwiftDependencyFingerprintProjection]
    private var compiledAgainstDependencies: [String: [String]] = [:]
    private var affectedSources: Set<String>
    private var pendingSources: Set<String>
    private var mutableCompilationCounts: [String: Int] = [:]

    public init(
        previousManifest: SwiftDependencyModuleManifest,
        expectedSourceIdentities: [String],
        changedSourceIdentities: Set<String>
    ) throws {
        let previousSources = previousManifest.sources.map(\.sourceIdentity).sorted()
        guard previousManifest.schema == SwiftDependencyModuleManifest.schema,
              expectedSourceIdentities.sorted() == previousSources,
              Set(expectedSourceIdentities).count == expectedSourceIdentities.count,
              changedSourceIdentities.isSubset(of: Set(previousSources)) else {
            throw StubError.error("Swift dependency fixed-point scheduling requires the complete unchanged source topology.")
        }
        self.previousManifest = previousManifest
        self.previousEntries = Dictionary(
            uniqueKeysWithValues: previousManifest.sources.map { ($0.sourceIdentity, $0) }
        )
        self.projectionsBySource = Dictionary(
            uniqueKeysWithValues: previousManifest.sources.map { ($0.sourceIdentity, $0.projection) }
        )
        self.affectedSources = changedSourceIdentities
        self.pendingSources = changedSourceIdentities
    }

    public var nextSourceIdentity: String? {
        pendingSources.min()
    }

    public var pendingSourceIdentities: [String] {
        pendingSources.sorted()
    }

    public var compilationCounts: [String: Int] {
        mutableCompilationCounts
    }

    public var isComplete: Bool {
        pendingSources.isEmpty
    }

    /// Records the compiler projection produced for one pending source and
    /// schedules every direct or previously compiled caller whose dependency
    /// fingerprints are now stale. A caller may be re-enqueued if a provider
    /// changes after the caller compiled.
    public mutating func recordCompiledProjection(
        _ projection: SwiftDependencyFingerprintProjection,
        for sourceIdentity: String
    ) throws {
        guard pendingSources.contains(sourceIdentity),
              projection.schema == SwiftDependencyFingerprintProjection.schema,
              projection.compilerVersion == previousManifest.compilerVersion,
              projection.sourceFileInterfaceFingerprint != nil else {
            throw StubError.error("Swift dependency scheduler accepts only a valid projection for a pending source.")
        }

        projectionsBySource[sourceIdentity] = projection
        pendingSources.remove(sourceIdentity)
        affectedSources.insert(sourceIdentity)
        mutableCompilationCounts[sourceIdentity, default: 0] += 1

        let orderedSources = previousManifest.sources.map(\.sourceIdentity)
        let projections = orderedSources.compactMap { projectionsBySource[$0] }
        guard projections.count == orderedSources.count,
              let providers = SwiftDependencyFingerprintResolver.providerFingerprints(from: projections) else {
            throw StubError.error("Swift dependency scheduler could not resolve the complete provider set.")
        }
        let resolvedDependencies = Dictionary(uniqueKeysWithValues: orderedSources.map { identity in
            let sourceProjection = projectionsBySource[identity]!
            return (
                identity,
                SwiftDependencyFingerprintResolver.localIdentityDigests(
                    for: sourceProjection,
                    providers: providers
                )
            )
        })

        compiledAgainstDependencies[sourceIdentity] = resolvedDependencies[sourceIdentity]!
        for identity in orderedSources where identity != sourceIdentity && !pendingSources.contains(identity) {
            let retainedDependencies = compiledAgainstDependencies[identity]
                ?? previousEntries[identity]!.dependencyFingerprintDigests
            if resolvedDependencies[identity] != retainedDependencies {
                pendingSources.insert(identity)
                affectedSources.insert(identity)
            }
        }
    }

    public func result() throws -> SwiftDependencyFixedPointResult {
        guard pendingSources.isEmpty else {
            throw StubError.error("Swift dependency scheduler has not reached a fixed point.")
        }
        let currentManifest = try SwiftDependencyModuleManifest(
            moduleName: previousManifest.moduleName,
            toolchainIdentity: previousManifest.toolchainIdentity,
            pathPolicyIdentity: previousManifest.pathPolicyIdentity,
            expectedSourceIdentities: previousManifest.sources.map(\.sourceIdentity),
            projectionsBySource: projectionsBySource
        )
        let allSources = Set(previousManifest.sources.map(\.sourceIdentity))
        return .init(
            manifest: currentManifest,
            invalidationCone: .init(
                affectedSources: affectedSources.sorted(),
                reusableSources: allSources.subtracting(affectedSources).sorted()
            ),
            compilationCounts: mutableCompilationCounts
        )
    }
}

#endif
