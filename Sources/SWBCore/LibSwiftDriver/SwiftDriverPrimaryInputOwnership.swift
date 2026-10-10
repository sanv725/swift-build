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

    /// Opt-in ownership follows filesystem identity without rewriting serialized commands.
    public static func owns(source: String, arguments: [String], inputs: [String],
                            canonicalize: (String) -> String?, isRegularFile: (String) -> Bool) -> Bool {
        owns(source: source, arguments: arguments, inputs: inputs, canonicalize: canonicalize,
             isRegularFile: isRegularFile, readFileList: nil)
    }

    /// As above. A `-filelist` (non-primary module sources, used by large targets) is
    /// accepted only when `readFileList` is supplied, the command has exactly one
    /// `-filelist <absolute path>`, and the list's canonical entries equal the job's
    /// canonical Swift inputs. Then the list cannot hide a source. Primaries must
    /// still be explicit `-primary-file` arguments. Response files,
    /// `-primary-filelist` and whole-module builds remain unsupported.
    public static func owns(source: String, arguments: [String], inputs: [String],
                            canonicalize: (String) -> String?, isRegularFile: (String) -> Bool,
                            readFileList: ((String) -> [String]?)?) -> Bool {
        guard source.hasPrefix("/"), let selected = canonicalize(source), isRegularFile(source),
              !arguments.contains(where: {
                  $0.hasPrefix("@") || $0.hasPrefix("-primary-filelist") ||
                  ($0.hasPrefix("-filelist") && ($0 != "-filelist" || readFileList == nil)) ||
                  $0 == "-wmo" || $0 == "-whole-module-optimization"
              }) else { return false }
        var canonicalInputs = Set<String>()
        for input in inputs {
            guard input.hasPrefix("/"), let path = canonicalize(input) else { return false }
            canonicalInputs.insert(path)
        }
        guard canonicalInputs.contains(selected) else { return false }
        let fileLists = arguments.indices.filter { arguments[$0] == "-filelist" }
        if !fileLists.isEmpty {
            guard fileLists.count == 1, let readFileList, fileLists[0] + 1 < arguments.count,
                  arguments[fileLists[0] + 1].hasPrefix("/"),
                  let entries = readFileList(arguments[fileLists[0] + 1]), !entries.isEmpty else { return false }
            var listed = Set<String>()
            for entry in entries {
                guard entry.hasPrefix("/"), let path = canonicalize(entry), listed.insert(path).inserted else { return false }
            }
            guard listed == canonicalInputs.filter({ $0.hasSuffix(".swift") }) else { return false }
        }
        var primaries = Set<String>()
        for index in arguments.indices where arguments[index] == "-primary-file" {
            guard index + 1 < arguments.count, arguments[index + 1].hasPrefix("/"),
                  let path = canonicalize(arguments[index + 1]), isRegularFile(arguments[index + 1]),
                  primaries.insert(path).inserted else { return false }
        }
        return !primaries.isEmpty && primaries.isSubset(of: canonicalInputs) && primaries.contains(selected)
    }

    /// Narrows an invalidated batch compile to the primaries that own an edited source
    /// (SwiftBuildOptimizer C971). The recorded batch partition otherwise recompiles every
    /// batch-mate of an edited file; stock incremental builds compile only the edited one.
    /// A dropped primary's source is unchanged since the record, so its outputs from the
    /// last build stand, as they do for every other replayed job of the module.
    ///
    /// Returns the argument indices to remove and the dropped primaries (as written), or
    /// nil to keep the whole batch. Only explicit `-primary-file` primaries with one `-o`
    /// each (and optionally one `-index-unit-output-path` each), in the same order, are
    /// narrowed; response files, output filelists, module emission and whole-module builds
    /// are not. Every dropped primary's object output must be an existing regular file.
    /// Without `-filelist` a dropped primary stays in place as an ordinary input; with one
    /// (whose entries include the primaries) its `-primary-file` pair is removed.
    ///
    /// `retained` (SwiftBuildOptimizer C990) receives a selected primary and its object path (as
    /// written) and returns true when that primary's last compile in this plan generation still
    /// stands: same content, same object file. Such a primary is dropped like an unselected one,
    /// but only while another selected primary is kept; when every selected primary is retained,
    /// all of them are kept (the compile task may then reuse them as a whole). `retained` in the
    /// result counts the dropped retained primaries.
    public static func narrowedBatch(arguments: [String], keeping selected: Set<String>,
                                     canonicalize: (String) -> String?,
                                     isRegularFile: (String) -> Bool,
                                     retained: ((_ primary: String, _ object: String) -> Bool)? = nil)
        -> (removed: Set<Int>, dropped: [String], retained: Int)? {
        guard !arguments.contains(where: {
                  $0.hasPrefix("@") || $0.hasPrefix("-primary-filelist") || $0.hasPrefix("-output-filelist") ||
                  $0.hasPrefix("-index-unit-output-path-filelist") || $0.hasPrefix("-emit-module") ||
                  $0 == "-wmo" || $0 == "-whole-module-optimization"
              }) else { return nil }
        let primaries = arguments.indices.filter { arguments[$0] == "-primary-file" }
        let objects = arguments.indices.filter { arguments[$0] == "-o" }
        let units = arguments.indices.filter { arguments[$0] == "-index-unit-output-path" }
        guard primaries.count > 1, objects.count == primaries.count,
              units.isEmpty || units.count == primaries.count,
              (primaries + objects + units).allSatisfy({ $0 + 1 < arguments.count && arguments[$0 + 1].hasPrefix("/") })
        else { return nil }
        var kept = 0
        var removed = Set<Int>()
        var dropped: [String] = []
        var retainedPositions: [Int] = []
        let fileList = arguments.contains("-filelist")
        func drop(_ position: Int) {
            let index = primaries[position]
            removed.insert(index)
            if fileList { removed.insert(index + 1) }
            removed.formUnion([objects[position], objects[position] + 1])
            if !units.isEmpty { removed.formUnion([units[position], units[position] + 1]) }
            dropped.append(arguments[index + 1])
        }
        for (position, index) in primaries.enumerated() {
            guard let path = canonicalize(arguments[index + 1]) else { return nil }
            if selected.contains(path) {
                if let retained, retained(arguments[index + 1], arguments[objects[position] + 1]) {
                    retainedPositions.append(position)
                } else {
                    kept += 1
                }
                continue
            }
            guard isRegularFile(arguments[objects[position] + 1]) else { return nil }
            drop(position)
        }
        if kept > 0 {
            retainedPositions.forEach(drop)
        } else {
            kept = retainedPositions.count
            retainedPositions = []
        }
        return kept > 0 && !dropped.isEmpty ? (removed, dropped, retainedPositions.count) : nil
    }

    /// Parses a driver response file written with `spm_shellEscaped` (one argument per line;
    /// single-quoted when needed, with embedded quotes written as '\\''). Callers must verify the
    /// result against the planned command-line signature.
    public static func parseResponseFile(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard line.count >= 2, line.hasPrefix("'"), line.hasSuffix("'") else { return String(line) }
            let inner = line.dropFirst().dropLast()
            let pattern = "'\\''"
            var result = ""
            var index = inner.startIndex
            while index < inner.endIndex {
                if inner[index...].hasPrefix(pattern) {
                    result.append("'")
                    index = inner.index(index, offsetBy: pattern.count)
                } else {
                    result.append(inner[index])
                    index = inner.index(after: index)
                }
            }
            return result
        }
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
        provesAbsence(source: source, arguments: arguments, inputs: inputs, isCompile: isCompile,
                      canonicalize: canonicalize, isRegularFile: isRegularFile, readFileList: nil, rejection: nil)
    }

    /// As above. With `readFileList`, one `-filelist <absolute path>` is accepted when its
    /// canonical entries exclude the source and equal the job's canonical Swift inputs.
    /// `rejection` receives a short reason when the proof fails (diagnostic only).
    /// `referenced` receives each uncanonicalized value compared with the source; every other
    /// comparison is against a `canonicalize` result.
    public static func provesAbsence(source: String, arguments: [String], inputs: [String],
                                     isCompile: Bool,
                                     canonicalize: (String) -> String?,
                                     isRegularFile: (String) -> Bool,
                                     readFileList: ((String) -> [String]?)?,
                                     rejection: ((String) -> Void)?,
                                     referenced: ((String) -> Void)? = nil) -> Bool {
        func reject(_ reason: String) -> Bool { rejection?(reason); return false }
        guard source.hasPrefix("/"), let source = canonicalize(source) else { return reject("source") }
        if let flag = arguments.first(where: {
                  $0.hasPrefix("@") || $0.hasPrefix("-primary-filelist") ||
                  ($0.hasPrefix("-filelist") && ($0 != "-filelist" || readFileList == nil)) ||
                  $0.hasPrefix("-index-unit-output-path-filelist") ||
                  $0 == "-wmo" ||
                  $0 == "-whole-module-optimization" ||
                  ($0.hasPrefix("-load-resolved-plugin") && $0 != "-load-resolved-plugin") ||
                  ($0.hasPrefix("-index-unit-output-path") && $0 != "-index-unit-output-path")
              }) { return reject("unsupported-flag " + String(flag.prefix(40))) }
        var primaries = Set<String>()
        for index in arguments.indices where arguments[index] == "-primary-file" {
            guard index + 1 < arguments.count,
                  arguments[index + 1].hasPrefix("/"),
                  let primary = canonicalize(arguments[index + 1]),
                  primaries.insert(primary).inserted else { return reject("primary") }
        }
        guard !isCompile || !primaries.isEmpty else { return reject("compile-without-primary") }
        var canonicalInputs = Set<String>()
        for input in inputs {
            guard input.hasPrefix("/"), let path = canonicalize(input) else { return reject("input-unresolved") }
            guard path != source else { return reject("source-is-input") }
            canonicalInputs.insert(path)
        }
        guard primaries.isSubset(of: canonicalInputs) else { return reject("primary-not-input") }
        var operandIndices = Set<Int>()
        var indexMetadata = Set<String>()
        var pluginOperands = Set<String>()
        var pluginModules = Set<String>()
        func moduleIdentifier(_ value: Substring) -> Bool {
            let characters = Array(value.utf8)
            func letter(_ c: UInt8) -> Bool { c == 95 || (65...90).contains(c) || (97...122).contains(c) }
            guard let first = characters.first, letter(first) else { return false }
            return characters.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) }
        }
        let fileLists = arguments.indices.filter { arguments[$0] == "-filelist" }
        if !fileLists.isEmpty {
            guard fileLists.count == 1, let readFileList, fileLists[0] + 1 < arguments.count,
                  arguments[fileLists[0] + 1].hasPrefix("/"),
                  let entries = readFileList(arguments[fileLists[0] + 1]), !entries.isEmpty else { return reject("filelist-unreadable") }
            var listed = Set<String>()
            for entry in entries {
                guard entry.hasPrefix("/"), let path = canonicalize(entry), path != source,
                      listed.insert(path).inserted else { return reject("filelist-entry") }
            }
            guard listed == canonicalInputs.filter({ $0.hasSuffix(".swift") }) else { return reject("filelist-mismatch") }
            operandIndices.insert(fileLists[0] + 1)
        }
        // SwiftOptions: -load-resolved-plugin <library>#<executable>#<modules>;
        // -index-unit-output-path is index identity metadata, not a read input.
        for index in arguments.indices {
            if arguments[index] == "-load-resolved-plugin" {
                // Several distinct macro plugins may be loaded; each operand is validated
                // independently, and repeated operands or module names stay rejected.
                guard index + 1 < arguments.count, pluginOperands.insert(arguments[index + 1]).inserted else { return reject("plugin") }
                let parts = arguments[index + 1].split(separator: "#", omittingEmptySubsequences: false)
                guard parts.count == 3, !parts[0].isEmpty || !parts[1].isEmpty else { return reject("plugin") }
                for component in parts.prefix(2) where !component.isEmpty {
                    let file = String(component)
                    guard file.hasPrefix("/"), !file.utf8.contains(0),
                          let path = canonicalize(file), path != source,
                          isRegularFile(file) else { return reject("plugin-file") }
                }
                let modules = parts[2].split(separator: ",", omittingEmptySubsequences: false)
                guard !modules.isEmpty, Set(modules).count == modules.count,
                      modules.allSatisfy(moduleIdentifier),
                      modules.allSatisfy({ pluginModules.insert(String($0)).inserted }) else { return reject("plugin-modules") }
                operandIndices.insert(index + 1)
            } else if arguments[index] == "-index-unit-output-path" {
                guard index + 1 < arguments.count else { return reject("index-unit") }
                let value = arguments[index + 1]
                referenced?(value)
                guard value.hasPrefix("/"), !value.utf8.contains(0), value != source,
                      indexMetadata.insert(value).inserted else { return reject("index-unit") }
                operandIndices.insert(index + 1)
            }
        }
        for (index, argument) in arguments.enumerated() where !operandIndices.contains(index) {
            if argument.hasPrefix("/") {
                guard let path = canonicalize(argument) else {
                    let previous = index > 0 ? arguments[index - 1] : ""
                    return reject("unresolved-path after " + String(previous.prefix(40)))
                }
                guard path != source else { return reject("source-argument") }
            } else if argument.hasSuffix(".swift") || argument.hasSuffix(".swiftinterface") {
                return reject("relative-swift-argument")
            }
        }
        return primaries.contains(source) ? reject("source-is-primary") : true
    }

}
