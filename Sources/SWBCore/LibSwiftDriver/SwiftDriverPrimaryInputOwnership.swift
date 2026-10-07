//===----------------------------------------------------------------------===//
// Part of the Swift open source project. Licensed under Apache License v2.0
// with Runtime Library Exception. See https://swift.org/LICENSE.txt.
//===----------------------------------------------------------------------===//

/// Conservative ownership for the opt-in single-source cached-plan experiment.
/// A frontend reads other same-module files without owning their object outputs.
/// Explicit batch primaries own their whole job: invalidating one source must
/// invalidate that job's entire set of compilation cache keys. Never infer
/// ownership from non-primary inputs, response files, or WMO dependencies.
public enum SwiftDriverPrimaryInputOwnership {
    public static func owns(source: String, arguments: [String], inputs: [String]) -> Bool {
        guard source.hasPrefix("/"), inputs.contains(source),
              !arguments.contains(where: { $0.hasPrefix("@") || $0.hasPrefix("-primary-filelist") }) else {
            return false
        }
        var primary: [String] = []
        for index in arguments.indices where arguments[index] == "-primary-file" {
            guard index + 1 < arguments.count,
                  arguments[index + 1].hasPrefix("/") else { return false }
            primary.append(arguments[index + 1])
        }
        return !primary.isEmpty && Set(primary).count == primary.count
            && primary.contains(source)
    }

    /// Positive absence proof for experimental native planning. Unsupported
    /// ownership and unresolved aliases remain unknown, never "unaffected".
    public static func provesAbsence(source: String, arguments: [String], inputs: [String],
                                     isCompile: Bool,
                                     canonicalize: (String) -> String?) -> Bool {
        guard source.hasPrefix("/"), let source = canonicalize(source),
              !arguments.contains(where: {
                  $0.hasPrefix("@") || $0.hasPrefix("-primary-filelist") ||
                  $0.hasPrefix("-filelist") || $0 == "-wmo" ||
                  $0 == "-whole-module-optimization"
              }) else { return false }
        var primaries = Set<String>()
        for index in arguments.indices where arguments[index] == "-primary-file" {
            guard index + 1 < arguments.count,
                  arguments[index + 1].hasPrefix("/"),
                  let primary = canonicalize(arguments[index + 1]),
                  primaries.insert(primary).inserted else { return false }
        }
        guard !isCompile || !primaries.isEmpty else { return false }
        var canonicalInputs = Set<String>()
        for input in inputs {
            guard input.hasPrefix("/"), let path = canonicalize(input), path != source else { return false }
            canonicalInputs.insert(path)
        }
        guard primaries.isSubset(of: canonicalInputs) else { return false }
        for argument in arguments {
            if argument.hasPrefix("/") {
                guard let path = canonicalize(argument), path != source else { return false }
            } else if argument.hasSuffix(".swift") || argument.hasSuffix(".swiftinterface") {
                return false
            }
        }
        return !primaries.contains(source)
    }

}
