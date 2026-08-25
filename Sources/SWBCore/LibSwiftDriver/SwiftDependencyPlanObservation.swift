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

/// A content-independent description of the part of a Swift Driver plan that
/// may be considered for an unseen source state. This is an observation-only
/// compatibility contract; it does not install or execute a cached plan.
public struct SwiftDependencyPlanBinding: Codable, Sendable, Equatable {
    public static let schema = "swift-build-dependency-plan-binding-v1"

    public struct Job: Codable, Sendable, Equatable, Comparable {
        public let identity: String
        public let primarySourceIdentity: String?
        public let dependencies: [String]
        public let commandShape: [String]
        public let outputShape: [String]

        public init(
            identity: String,
            primarySourceIdentity: String?,
            dependencies: [String],
            commandShape: [String],
            outputShape: [String]
        ) {
            self.identity = identity
            self.primarySourceIdentity = primarySourceIdentity
            self.dependencies = dependencies.sorted()
            self.commandShape = commandShape
            self.outputShape = outputShape
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.identity < rhs.identity
        }
    }

    public enum Incompatibility: String, Codable, Sendable, Equatable {
        case schema
        case moduleStructure
        case planInputs
        case integrity
    }

    public enum Observation: Sendable, Equatable {
        case compatible(planStructureIdentity: String)
        case incompatible(Incompatibility)
    }

    public let schema: String
    public let moduleStructureIdentity: String
    public let planInputIdentity: String
    public let jobs: [Job]
    public let lookupIdentity: String
    public let planStructureIdentity: String

    public init(
        moduleManifest: SwiftDependencyModuleManifest,
        planInputIdentity: String,
        jobs: [Job]
    ) throws {
        let sortedJobs = jobs.sorted()
        guard Self.isDigest(planInputIdentity) else {
            throw StubError.error("Swift dependency plan input identity must be a lowercase SHA-256 digest.")
        }
        guard Self.validTopology(jobs: sortedJobs, sources: moduleManifest.sources.map(\.sourceIdentity)) else {
            throw StubError.error("Swift dependency plan must be an acyclic graph with exact primary-source coverage.")
        }

        self.schema = Self.schema
        self.moduleStructureIdentity = moduleManifest.structureIdentity
        self.planInputIdentity = planInputIdentity
        self.jobs = sortedJobs
        self.lookupIdentity = try Self.lookupIdentity(
            moduleManifest: moduleManifest,
            planInputIdentity: planInputIdentity
        )
        self.planStructureIdentity = Self.structureDigest(
            moduleStructureIdentity: moduleManifest.structureIdentity,
            planInputIdentity: planInputIdentity,
            jobs: sortedJobs
        )
    }

    /// Validates a decoded candidate against the current content-independent
    /// module state and normalized planning inputs. A compatible result is
    /// evidence only; callers must still use Apple's planning path.
    public func observe(
        currentManifest: SwiftDependencyModuleManifest,
        currentPlanInputIdentity: String
    ) -> Observation {
        guard schema == Self.schema else { return .incompatible(.schema) }
        guard moduleStructureIdentity == currentManifest.structureIdentity else {
            return .incompatible(.moduleStructure)
        }
        guard planInputIdentity == currentPlanInputIdentity else {
            return .incompatible(.planInputs)
        }
        let sourceIdentities = currentManifest.sources.map(\.sourceIdentity)
        guard Self.validTopology(jobs: jobs, sources: sourceIdentities),
              lookupIdentity == Self.digest(fields: [
                "swift-build-dependency-plan-lookup-v1",
                moduleStructureIdentity,
                planInputIdentity,
              ]),
              planStructureIdentity == Self.structureDigest(
                moduleStructureIdentity: moduleStructureIdentity,
                planInputIdentity: planInputIdentity,
                jobs: jobs
              ) else {
            return .incompatible(.integrity)
        }
        return .compatible(planStructureIdentity: planStructureIdentity)
    }

    public static func lookupIdentity(
        moduleManifest: SwiftDependencyModuleManifest,
        planInputIdentity: String
    ) throws -> String {
        guard isDigest(planInputIdentity) else {
            throw StubError.error("Swift dependency plan input identity must be a lowercase SHA-256 digest.")
        }
        return digest(fields: [
            "swift-build-dependency-plan-lookup-v1",
            moduleManifest.structureIdentity,
            planInputIdentity,
        ])
    }

    private static func validTopology(jobs: [Job], sources: [String]) -> Bool {
        guard !jobs.isEmpty,
              jobs.allSatisfy({ !$0.identity.isEmpty && !$0.commandShape.isEmpty }) else {
            return false
        }
        let identities = jobs.map(\.identity)
        let identitySet = Set(identities)
        guard identitySet.count == identities.count else { return false }
        let primaries = jobs.compactMap(\.primarySourceIdentity).sorted()
        guard primaries == sources.sorted() else { return false }
        guard jobs.allSatisfy({ job in
            !job.dependencies.contains(job.identity)
                && job.dependencies.allSatisfy(identitySet.contains)
        }) else { return false }

        var dependents: [String: [String]] = [:]
        var remainingDependencies: [String: Int] = [:]
        for job in jobs {
            remainingDependencies[job.identity] = job.dependencies.count
            for dependency in job.dependencies {
                dependents[dependency, default: []].append(job.identity)
            }
        }
        var ready = remainingDependencies.compactMap { key, count in count == 0 ? key : nil }
        var visited = 0
        while let identity = ready.popLast() {
            visited += 1
            for dependent in dependents[identity, default: []] {
                let remaining = remainingDependencies[dependent, default: 0] - 1
                remainingDependencies[dependent] = remaining
                if remaining == 0 { ready.append(dependent) }
            }
        }
        return visited == jobs.count
    }

    private static func structureDigest(
        moduleStructureIdentity: String,
        planInputIdentity: String,
        jobs: [Job]
    ) -> String {
        var fields = [
            Self.schema,
            moduleStructureIdentity,
            planInputIdentity,
            "jobs-v1",
        ]
        for job in jobs.sorted() {
            fields.append(job.identity)
            fields.append(job.primarySourceIdentity ?? "")
            fields.append("dependencies-v1")
            fields.append(contentsOf: job.dependencies)
            fields.append("command-shape-v1")
            fields.append(contentsOf: job.commandShape)
            fields.append("output-shape-v1")
            fields.append(contentsOf: job.outputShape)
        }
        return digest(fields: fields)
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

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    }
}

#endif
