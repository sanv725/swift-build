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
}
