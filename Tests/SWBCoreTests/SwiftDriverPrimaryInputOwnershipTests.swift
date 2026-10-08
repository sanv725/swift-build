//===----------------------------------------------------------------------===//
// Part of the Swift open source project. Licensed under Apache v2.0
// with Runtime Library Exception. See https://swift.org/LICENSE.txt.
//===----------------------------------------------------------------------===//

import Testing
import SWBCore

@Suite
struct SwiftDriverPrimaryInputOwnershipTests {
    private let source = "/tmp/App/Changed.swift"

    @Test
    func acceptsOnlyTheExplicitOwningPrimary() {
        let arguments = ["swift-frontend", "-primary-file", "/tmp/App/Other.swift",
                         "-primary-file", source, "-primary-file", "/tmp/App/Third.swift"]
        let inputs = ["/tmp/App/Other.swift", source, "/tmp/App/Third.swift"]
        #expect(SwiftDriverPrimaryInputOwnership.owns(
            source: source, arguments: arguments, inputs: inputs))
        #expect(!SwiftDriverPrimaryInputOwnership.owns(
            source: "/tmp/App/Dependency.swift", arguments: arguments,
            inputs: inputs + ["/tmp/App/Dependency.swift"]))
    }

    @Test
    func rejectsAmbiguousOrUnlistedBatchPrimaries() {
        let inputs = [source, "/tmp/App/Other.swift"]
        for arguments in [
            ["swift-frontend", "-primary-file", source, "-primary-file", source],
            ["swift-frontend", "-primary-file", source, "-primary-file", "Other.swift"],
            ["swift-frontend", "-primary-file", source, "@options.rsp"],
            ["swift-frontend", "-primary-file", source, "-primary-filelist", "/tmp/list"],
            ["swift-frontend", "-primary-file", "/tmp/App/Other.swift"],
            ["swift-frontend", "-primary-file"],
        ] {
            #expect(!SwiftDriverPrimaryInputOwnership.owns(
                source: source, arguments: arguments, inputs: inputs))
        }
        #expect(!SwiftDriverPrimaryInputOwnership.owns(
            source: source, arguments: ["swift-frontend", "-primary-file", source],
            inputs: ["/tmp/App/Other.swift"]))
    }

    @Test
    func positiveAbsenceRequiresResolvedCompletePrimaryInputs() {
        let other = "/tmp/Dependency/Other.swift"
        let arguments = ["swift-frontend", "-primary-file", other]
        let canonicalize: (String) -> String? = { $0 == "/tmp/alias.swift" ? source : $0 }
        #expect(SwiftDriverPrimaryInputOwnership.provesAbsence(
            source: source, arguments: arguments, inputs: [other], isCompile: true,
            canonicalize: canonicalize))
        for (args, inputs) in [
            (arguments, [other, source]),
            (arguments, [other, "/tmp/alias.swift"]),
            (arguments + [source], [other]),
            (arguments + ["@options.rsp"], [other]),
            (arguments + ["-filelist", "/tmp/list"], [other]),
            (arguments + ["-primary-filelist=/tmp/list"], [other]),
            (arguments + ["-wmo"], [other]),
            (arguments + ["-whole-module-optimization"], [other]),
            (arguments + ["Other.swift"], [other]),
            (arguments + ["-primary-file", other], [other]),
            (arguments, []),
            (["swift-frontend", "-primary-file"], [other]),
            (["swift-frontend"], [other]),
        ] {
            #expect(!SwiftDriverPrimaryInputOwnership.provesAbsence(
                source: source, arguments: args, inputs: inputs, isCompile: true,
                canonicalize: canonicalize))
        }
        #expect(!SwiftDriverPrimaryInputOwnership.provesAbsence(
            source: source, arguments: arguments, inputs: [other], isCompile: true,
            canonicalize: { _ in nil }))
        #expect(!SwiftDriverPrimaryInputOwnership.provesAbsence(
            source: "Changed.swift", arguments: arguments, inputs: [other], isCompile: true,
            canonicalize: canonicalize))
    }

    @Test
    func selectedMetadataRolesRemainPositionalAndPluginFilesRequired() {
        let other = "/tmp/Dependency.swift", library = "/tmp/plugin.dylib", executable = "/tmp/plugin-helper"
        let base = ["swift-frontend", "-primary-file", other]
        let plugin = library + "#" + executable + "#MacroModule"
        let canonicalize: (String) -> String? = { value in
            if value == "/missing/index.o" || value == "/missing/plugin" { return nil }
            return value == "/tmp/source-alias" ? self.source : value
        }
        let regular: (String) -> Bool = { $0 == library || $0 == executable || $0 == "/tmp/source-alias" }
        func absence(_ arguments: [String], _ inputs: [String] = ["/tmp/Dependency.swift"]) -> Bool {
            SwiftDriverPrimaryInputOwnership.provesAbsence(source: source, arguments: arguments,
                inputs: inputs, isCompile: true, canonicalize: canonicalize, isRegularFile: regular)
        }
        #expect(absence(base + ["-load-resolved-plugin", plugin, "-index-unit-output-path", "/missing/index.o"]))
        #expect(absence(base + ["-load-resolved-plugin", "#" + executable + "#MacroModule"]))
        #expect(absence(base + ["-load-resolved-plugin", library + "##MacroModule"]))
        #expect(!SwiftDriverPrimaryInputOwnership.provesAbsence(source: source,
            arguments: base + ["-load-resolved-plugin", plugin], inputs: [other],
            isCompile: true, canonicalize: canonicalize))
        for operand in [
            "##MacroModule", library + "#MacroModule", plugin + "#extra",
            library + "#" + executable + "#", library + "#" + executable + "#MacroModule,",
            library + "#" + executable + "#MacroModule,MacroModule",
            library + "#" + executable + "#9Bad", library + "#" + executable + "#Bad/Module",
            "/missing/plugin#" + executable + "#MacroModule",
            "/tmp/directory#" + executable + "#MacroModule",
            "/tmp/source-alias#" + executable + "#MacroModule",
            library + "#/tmp/source-alias#MacroModule",
            "relative#" + executable + "#MacroModule",
        ] { #expect(!absence(base + ["-load-resolved-plugin", operand])) }
        #expect(!absence(base + ["-load-resolved-plugin"]))
        #expect(!absence(base + ["-index-unit-output-path"]))
        #expect(!absence(base + ["-index-unit-output-path", "relative.o"]))
        #expect(!absence(base + ["-index-unit-output-path", source]))
        #expect(!absence(base + ["-index-unit-output-path-filelist", "/tmp/list"]))
        #expect(!absence(base + ["-index-unit-output-path=/missing/index.o"]))
        #expect(!absence(base + ["-load-resolved-plugin=" + plugin]))
        #expect(!absence(base + ["-load-resolved-plugin", plugin, "-load-resolved-plugin", plugin]))
        #expect(!absence(base + ["-index-unit-output-path", "/missing/index.o", "-index-unit-output-path", "/missing/index.o"]))
        #expect(!absence(base + ["-index-unit-output-path", "/missing/index.o"], [other, "/missing/index.o"]))
        #expect(!absence(base + ["-index-unit-output-path", "/missing/index.o", "/missing/index.o"]))
        #expect(!absence(base + ["-load-resolved-plugin", plugin], [other, source]))
    }
}

@Suite struct CanonicalPrimaryOwnershipTests {
    @Test func canonicalAliasesDoNotBroadenOwnership() {
        let source = "/private/tmp/Probe/Value.swift"
        let alias = "/tmp/Probe/Value.swift"
        let other = "/private/tmp/Probe/Other.swift"
        func canonical(_ value: String) -> String? {
            if value == source || value == alias { return source }
            if value == other { return other }
            return nil
        }
        func owns(_ args: [String], _ inputs: [String]) -> Bool {
            SwiftDriverPrimaryInputOwnership.owns(source: source, arguments: args,
                inputs: inputs, canonicalize: canonical, isRegularFile: { canonical($0) != nil })
        }
        #expect(owns(["-primary-file", alias], [alias]))
        #expect(!SwiftDriverPrimaryInputOwnership.owns(source: source,
            arguments: ["-primary-file", alias], inputs: [alias]))
        #expect(!owns(["-primary-file", other], [source, other]))
        #expect(!owns(["-primary-file", source, "-primary-file", alias], [source, alias]))
        #expect(!owns(["-primary-file", source], [other]))
        #expect(!owns(["-primary-file", "/tmp/Probe/Missing.swift"], [source]))
        for flag in ["@response", "-primary-filelist", "-filelist", "-wmo", "-whole-module-optimization"] {
            #expect(!owns(["-primary-file", source, flag], [source]))
        }
    }
}

@Suite struct ValidatedFileListOwnershipTests {
    // Large targets (Reframe, C959) pass non-primary sources with `-filelist` and keep
    // explicit `-primary-file` arguments. The list must equal the job's Swift inputs.
    let source = "/private/tmp/App/Edited.swift"
    let other = "/private/tmp/App/Other.swift"
    let list = "/private/tmp/DD/sources-1"

    func owns(_ args: [String], inputs: [String], entries: [String]?) -> Bool {
        let known: Set<String> = [source, other, "/private/tmp/App/Third.swift", list, "/private/tmp/DD/Module.swiftmodule"]
        func canonical(_ value: String) -> String? {
            let v = value.hasPrefix("/tmp/") ? "/private" + value : value
            return known.contains(v) ? v : nil
        }
        return SwiftDriverPrimaryInputOwnership.owns(source: source, arguments: args, inputs: inputs,
            canonicalize: canonical, isRegularFile: { canonical($0) != nil },
            readFileList: { $0 == list ? entries : nil })
    }

    @Test func acceptsMatchingFileListWithExplicitPrimary() {
        let args = ["-frontend", "-c", "-filelist", list, "-primary-file", source]
        #expect(owns(args, inputs: [source, other], entries: [source, other]))
        // `/tmp` aliases in the list canonicalize like the inputs do.
        #expect(owns(args, inputs: [source, other], entries: ["/tmp/App/Edited.swift", "/tmp/App/Other.swift"]))
        // Non-Swift inputs are not part of the source list.
        #expect(owns(args, inputs: [source, other, "/private/tmp/DD/Module.swiftmodule"], entries: [source, other]))
    }

    @Test func rejectsFileListThatDoesNotMatchInputs() {
        let args = ["-frontend", "-c", "-filelist", list, "-primary-file", source]
        #expect(!owns(args, inputs: [source, other], entries: [source]))                                    // missing
        #expect(!owns(args, inputs: [source, other], entries: [source, other, "/private/tmp/App/Third.swift"])) // extra
        #expect(!owns(args, inputs: [source, other], entries: [source, other, other]))                     // duplicate
        #expect(!owns(args, inputs: [source, other], entries: [source, "/private/tmp/App/Unknown.swift"]))  // unresolvable
        #expect(!owns(args, inputs: [source, other], entries: nil))                                          // unreadable
        #expect(!owns(args, inputs: [source, other], entries: []))                                           // empty
    }

    @Test func keepsOtherRefusals() {
        let base = ["-frontend", "-c", "-filelist", list]
        #expect(!owns(base + ["-primary-file", other], inputs: [source, other], entries: [source, other]))
        #expect(!owns(base + ["-filelist", list, "-primary-file", source], inputs: [source, other], entries: [source, other]))
        #expect(!owns(["-frontend", "-c", "-filelist=" + list, "-primary-file", source], inputs: [source, other], entries: [source, other]))
        for flag in ["@response", "-primary-filelist", "-wmo", "-whole-module-optimization"] {
            #expect(!owns(base + ["-primary-file", source, flag], inputs: [source, other], entries: [source, other]))
        }
        #expect(!owns(base, inputs: [source, other], entries: [source, other]))   // no explicit primary
    }
}

@Suite struct ValidatedFileListAbsenceTests {
    let source = "/private/tmp/App/Edited.swift"
    let a = "/private/tmp/Pkg/A.swift"
    let b = "/private/tmp/Pkg/B.swift"
    let list = "/private/tmp/DD/sources-2"

    func absent(_ args: [String], inputs: [String], entries: [String]?, reader: Bool = true) -> (Bool, [String]) {
        let known: Set<String> = [source, a, b, list]
        var reasons: [String] = []
        let result = SwiftDriverPrimaryInputOwnership.provesAbsence(source: source, arguments: args, inputs: inputs,
            isCompile: true, canonicalize: { known.contains($0) ? $0 : nil }, isRegularFile: { known.contains($0) },
            readFileList: reader ? { $0 == list ? entries : nil } : nil, rejection: { reasons.append($0) })
        return (result, reasons)
    }

    @Test func provesAbsenceThroughMatchingFileList() {
        let args = ["-frontend", "-c", "-filelist", list, "-primary-file", a]
        #expect(absent(args, inputs: [a, b], entries: [a, b]).0)
    }

    @Test func refusesUnsafeFileLists() {
        let args = ["-frontend", "-c", "-filelist", list, "-primary-file", a]
        #expect(!absent(args, inputs: [a, b], entries: [a, b, source]).0)        // lists the edited source
        #expect(!absent(args, inputs: [a, b], entries: [a]).0)                   // incomplete
        #expect(!absent(args, inputs: [a, b], entries: nil).0)                   // unreadable
        #expect(!absent(args, inputs: [a, b], entries: [a, b], reader: false).0) // no reader: strict path
        let (ok, reasons) = absent(args + ["-filelist", list], inputs: [a, b], entries: [a, b])
        #expect(!ok && reasons == ["filelist-unreadable"])                       // two lists
    }
}

@Suite struct ResponseFileAndPluginAbsenceTests {
    @Test func parsesShellEscapedResponseFiles() {
        let text = ["-frontend", "'/tmp/A B/x.swift'", "'it'\\''s'", "-DFOO=1"].joined(separator: "\n")
        #expect(SwiftDriverPrimaryInputOwnership.parseResponseFile(text) == ["-frontend", "/tmp/A B/x.swift", "it's", "-DFOO=1"])
    }

    @Test func acceptsSeveralValidatedPlugins() {
        let source = "/private/tmp/App/Edited.swift"
        let input = "/private/tmp/Pkg/A.swift"
        let p1 = "/private/tmp/Plugins/libA.dylib", p2 = "/private/tmp/Plugins/libB.dylib"
        let known: Set<String> = [source, input, p1, p2]
        func absent(_ args: [String]) -> Bool {
            SwiftDriverPrimaryInputOwnership.provesAbsence(source: source, arguments: args, inputs: [input],
                isCompile: true, canonicalize: { known.contains($0) ? $0 : nil }, isRegularFile: { known.contains($0) },
                readFileList: nil, rejection: nil)
        }
        let base = ["-frontend", "-c", "-primary-file", input]
        #expect(absent(base + ["-load-resolved-plugin", p1 + "##MacroA", "-load-resolved-plugin", p2 + "##MacroB"]))
        #expect(!absent(base + ["-load-resolved-plugin", p1 + "##MacroA", "-load-resolved-plugin", source + "##MacroB"]))
        #expect(!absent(base + ["-load-resolved-plugin", p1 + "##Bad-Name"]))
    }
}
