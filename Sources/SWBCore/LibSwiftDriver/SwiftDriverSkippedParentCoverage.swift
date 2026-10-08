// Part of the Swift open source project. Licensed under Apache License v2.0
// with Runtime Library Exception. See https://swift.org/LICENSE.txt.

/// Narrow two-parent scheduling authority. Only terminal successful operations
/// with both exact static parents and no dynamic requests can prove planning skipped.
public struct SwiftDriverSkippedParentCoverage: Sendable {
    private struct Record: Sendable {
        var identity: String
        var roles: Set<String> = []
        var taskIDs: Set<String> = []
        var rejected = false
    }
    private var records: [String: Record] = [:]
    private var blockedKeys: Set<String> = []
    private var uncorrelatable = false
    public init() {}
    public mutating func observe(key: String, identity: String, role: String,
                                 taskID: String, upToDate: Bool) {
        var record = records[key] ?? Record(identity: identity)
        if record.identity != identity || !upToDate ||
            !["SwiftDriver Compilation Requirements", "SwiftDriver Compilation"].contains(role) ||
            record.roles.contains(role) || record.taskIDs.contains(taskID) {
            record.rejected = true
        }
        record.roles.insert(role); record.taskIDs.insert(taskID)
        records[key] = record
    }
    public mutating func requestedDynamicTask(key: String) { blockedKeys.insert(key) }
    public mutating func rejectUncorrelatableRequester() { uncorrelatable = true }
    public func qualifiedIdentity(key: String) -> String? { records[key]?.identity }
    public func terminalIdentityMatches(key: String, identity: String) -> Bool { records[key]?.identity == identity }
    /// Diagnostic only: why each observed key does or does not qualify.
    public func coverageSummary(operationSucceeded: Bool) -> String {
        let required = Set(["SwiftDriver Compilation Requirements", "SwiftDriver Compilation"])
        var counts: [String: Int] = [:]
        var examples: [String] = []
        for (key, r) in records.sorted(by: { $0.key < $1.key }) {
            let reason: String
            if r.rejected { reason = "rejected" }
            else if blockedKeys.contains(key) { reason = "dynamic-request" }
            else if r.roles != required { reason = "roles" }
            else { reason = "qualified" }
            counts[reason, default: 0] += 1
            if reason != "qualified", examples.count < 8 {
                examples.append("\(reason):[\(r.roles.sorted().joined(separator: "|"))]x\(r.taskIDs.count)")
            }
        }
        let summary = counts.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "SWIFT_DRIVER_SKIPPED_COVERAGE succeeded=\(operationSucceeded) uncorrelatable=\(uncorrelatable) keys=\(records.count) \(summary) examples=\(examples.joined(separator: ";"))"
    }

    public func qualifiedKeys(operationSucceeded: Bool) -> [String] {
        guard operationSucceeded, !uncorrelatable else { return [] }
        return records.keys.filter { key in
            guard let r = records[key] else { return false }
            return !r.rejected && !blockedKeys.contains(key) && r.roles ==
                Set(["SwiftDriver Compilation Requirements", "SwiftDriver Compilation"])
        }.sorted()
    }
}
