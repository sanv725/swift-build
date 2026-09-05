//===----------------------------------------------------------------------===//
// Part of the Swift open source project. Licensed under Apache License v2.0
// with Runtime Library Exception. See https://swift.org/LICENSE.txt.
//===----------------------------------------------------------------------===//

/// Conservative ownership for the opt-in single-source cached-plan experiment.
/// A frontend reads other same-module files without owning their object outputs.
/// Do not resolve response files or infer WMO/batch ownership from dependencies.
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
        return primary.count == 1 && primary[0] == source
    }
}
