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
        provesAbsence(source: source, arguments: arguments, inputs: inputs,
                      isCompile: isCompile, canonicalize: canonicalize,
                      isRegularFile: { _ in false })
    }

    /// Opt-in selected-toolchain grammar. The strict overload above never
    /// assumes that resolving a plugin path proves it is a regular file.
    public static func provesAbsence(source: String, arguments: [String], inputs: [String],
                                     isCompile: Bool,
                                     canonicalize: (String) -> String?,
                                     isRegularFile: (String) -> Bool) -> Bool {
        guard source.hasPrefix("/"), let source = canonicalize(source),
              !arguments.contains(where: {
                  $0.hasPrefix("@") || $0.hasPrefix("-primary-filelist") ||
                  $0.hasPrefix("-filelist") || $0.hasPrefix("-index-unit-output-path-filelist") ||
                  $0 == "-wmo" ||
                  $0 == "-whole-module-optimization" ||
                  ($0.hasPrefix("-load-resolved-plugin") && $0 != "-load-resolved-plugin") ||
                  ($0.hasPrefix("-index-unit-output-path") && $0 != "-index-unit-output-path")
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
        var operandIndices = Set<Int>()
        var pluginSeen = false
        var indexMetadata = Set<String>()
        func moduleIdentifier(_ value: Substring) -> Bool {
            let characters = Array(value.utf8)
            func letter(_ c: UInt8) -> Bool { c == 95 || (65...90).contains(c) || (97...122).contains(c) }
            guard let first = characters.first, letter(first) else { return false }
            return characters.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) }
        }
        // SwiftOptions: -load-resolved-plugin <library>#<executable>#<modules>;
        // -index-unit-output-path is index identity metadata, not a read input.
        for index in arguments.indices {
            if arguments[index] == "-load-resolved-plugin" {
                guard !pluginSeen, index + 1 < arguments.count else { return false }
                pluginSeen = true
                let parts = arguments[index + 1].split(separator: "#", omittingEmptySubsequences: false)
                guard parts.count == 3, !parts[0].isEmpty || !parts[1].isEmpty else { return false }
                for component in parts.prefix(2) where !component.isEmpty {
                    let file = String(component)
                    guard file.hasPrefix("/"), !file.utf8.contains(0),
                          let path = canonicalize(file), path != source,
                          isRegularFile(file) else { return false }
                }
                let modules = parts[2].split(separator: ",", omittingEmptySubsequences: false)
                guard !modules.isEmpty, Set(modules).count == modules.count,
                      modules.allSatisfy(moduleIdentifier) else { return false }
                operandIndices.insert(index + 1)
            } else if arguments[index] == "-index-unit-output-path" {
                guard index + 1 < arguments.count else { return false }
                let value = arguments[index + 1]
                guard value.hasPrefix("/"), !value.utf8.contains(0), value != source,
                      indexMetadata.insert(value).inserted else { return false }
                operandIndices.insert(index + 1)
            }
        }
        for (index, argument) in arguments.enumerated() where !operandIndices.contains(index) {
            if argument.hasPrefix("/") {
                guard let path = canonicalize(argument), path != source else { return false }
            } else if argument.hasSuffix(".swift") || argument.hasSuffix(".swiftinterface") {
                return false
            }
        }
        return !primaries.contains(source)
    }

}
