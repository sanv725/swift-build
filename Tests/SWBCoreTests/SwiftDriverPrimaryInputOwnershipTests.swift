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
}
