//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import SWBUtil
import SWBTaskExecution

@Suite
fileprivate struct SwiftDriverAbsenceCertificateTests {
    typealias Certificate = SwiftDriverAbsenceCertificate

    /// A filesystem model: `lstat` identities, resolutions, regular files and text identities.
    final class World {
        var entries: [String: Certificate.Identity] = [:]
        var resolutions: [String: String] = [:]
        var regularFiles = Set<String>()
        var texts: [String: Certificate.Identity] = [:]
        var resolveCount = 0
        private var nextInode: UInt64 = 1

        func identity(_ mtime: Int64 = 1) -> Certificate.Identity {
            nextInode += 1
            return .init(device: 1, inode: nextInode, mode: 0o040755, size: 0, modifiedNS: mtime, changedNS: mtime)
        }

        /// Adds a self-resolving path and its missing ancestors.
        func add(_ path: String) {
            var prefix: String? = path
            while let current = prefix {
                if entries[current] == nil { entries[current] = identity() }
                if resolutions[current] == nil { resolutions[current] = current }
                prefix = Certificate.parent(current)
            }
        }

        func touch(_ directory: String) {
            entries[directory]!.modifiedNS += 1; entries[directory]!.changedNS += 1
        }

        func resolve(_ path: String) -> String? { resolveCount += 1; return resolutions[path] }

        func recorder() -> Certificate.Recorder {
            Certificate.Recorder(lstat: { self.entries[$0] }, stat: { self.texts[$0] }, resolve: resolve)
        }

        func revalidate(_ certificate: Certificate) -> Certificate.Revalidation {
            certificate.revalidated(lstat: { self.entries[$0] }, stat: { self.texts[$0] },
                                    resolve: resolve, isRegularFile: { self.regularFiles.contains($0) })
        }
    }

    let plan = Certificate.Identity(device: 1, inode: 99, mode: 0o100644, size: 10, modifiedNS: 5, changedNS: 5)

    func certify(_ world: World, paths: [String], aliases: [String: String] = [:],
                 texts: [String] = [], regularFiles: [String] = []) throws -> Certificate {
        for path in paths { world.add(path) }
        for (alias, target) in aliases {
            world.add(target); world.add(Certificate.parent(alias)!)
            world.entries[alias] = world.identity(); world.resolutions[alias] = target
        }
        // `/tmp` is a symlink to `/private/tmp`, as on macOS.
        if world.resolutions["/tmp"] != nil { world.resolutions["/tmp"] = "/private/tmp" }
        for text in texts { world.texts[text] = world.identity() }
        for file in regularFiles { world.add(file); world.regularFiles.insert(file) }
        let recorder = world.recorder()
        var references = Set<String>()
        for path in paths + aliases.keys.sorted() + regularFiles {
            references.insert(try #require(recorder.canonical(path)))
        }
        for text in texts { _ = recorder.text(text) { _ in "contents" } }
        for file in regularFiles { _ = recorder.isRegularFile(file) { world.regularFiles.contains($0) } }
        return try #require(recorder.certificate(plan: plan, workingDirectory: "/w", references: references))
    }

    @Test
    func unchangedFilesystemRevalidatesWithoutResolving() throws {
        let world = World()
        let certificate = try certify(world, paths: ["/p/Sources/A.swift", "/p/Sources/B.swift", "/sdk/include"],
                                      aliases: ["/tmp/x.swift": "/private/tmp/x.swift",
                                                "/tmp/y.swift": "/private/tmp/y.swift",
                                                "/q/link": "/q/elsewhere/target"],
                                      texts: ["/d/list"], regularFiles: ["/t/plugin"])
        #expect(certificate.references.contains("/private/tmp/x.swift"))
        #expect(certificate.links == ["/q/link", "/tmp"])
        #expect(certificate.aliases.isEmpty)
        world.resolveCount = 0
        #expect(world.revalidate(certificate) == .valid(refreshed: nil))
        // Each link re-resolves once; self-resolving paths are covered by identities.
        #expect(world.resolveCount == 2)
        #expect(try Certificate.decode(certificate.encoded()) == certificate)
    }

    @Test
    func changedParentReresolvesOnlyItsChildren() throws {
        let world = World()
        let certificate = try certify(world, paths: ["/p/Sources/A.swift", "/p/Sources/B.swift", "/p/Other/C.swift"])
        // An atomic save replaces B.swift: new inode, and its directory's entries change.
        world.entries["/p/Sources/B.swift"] = world.identity()
        world.touch("/p/Sources")
        world.resolveCount = 0
        // A few re-resolutions cost less than rewriting the certificate.
        #expect(world.revalidate(certificate) == .valid(refreshed: nil))
        #expect(world.resolveCount == 2)

        let many = (0...Certificate.refreshThreshold).map { "/m/Sources/F\($0).swift" }
        let large = try certify(world, paths: many)
        world.touch("/m/Sources")
        guard case .valid(let refreshed?) = world.revalidate(large) else {
            Issue.record("expected a refreshed certificate"); return
        }
        world.resolveCount = 0
        #expect(world.revalidate(refreshed) == .valid(refreshed: nil))
        #expect(world.resolveCount == 0)
    }

    @Test
    func aliasThroughAnotherSymlinkStaysPlainAndLinkChangesAreStale() throws {
        let world = World()
        world.add("/s/real/Lib/Header.h")
        world.entries["/s/v2"] = world.identity()
        world.resolutions["/s/v2"] = "/s/real"
        // The rest of the path crosses a second link, so it does not map onto the link target.
        world.resolutions["/s/v2/Lib"] = "/s/real/Lib"
        world.resolutions["/s/v2/Lib/Header.h"] = "/s/other/Header.h"
        world.add("/s/other/Header.h")
        let recorder = world.recorder()
        let references = Set([try #require(recorder.canonical("/s/v2/Lib/Header.h"))])
        let certificate = try #require(recorder.certificate(plan: plan, workingDirectory: "/w", references: references))
        #expect(certificate.aliases == ["/s/v2/Lib/Header.h"])
        #expect(certificate.links.isEmpty)

        let linked = World()
        let viaLink = try certify(linked, paths: [], aliases: ["/tmp/z.swift": "/private/tmp/z.swift"])
        #expect(viaLink.links == ["/tmp"])
        linked.resolutions["/tmp"] = "/private/var/tmp"
        #expect(linked.revalidate(viaLink) == .stale("link-resolution"))
    }

    @Test
    func caseRenameOrSymlinkSwapMakesTheCertificateStale() throws {
        let world = World()
        let certificate = try certify(world, paths: ["/p/Views/A.swift"])
        // A case-only rename keeps the inode but changes the canonical spelling.
        world.touch("/p")
        world.resolutions["/p/Views"] = "/p/views"
        #expect(world.revalidate(certificate) == .stale("prefix-resolution"))

        let other = World()
        let swapped = try certify(other, paths: ["/q/Sources/A.swift"])
        other.entries["/q/Sources"] = other.identity()
        other.resolutions["/q/Sources"] = "/q/Moved"
        #expect(other.revalidate(swapped) == .stale("prefix-resolution"))
    }

    @Test
    func deletedPathAliasTextAndPluginChangesAreStale() throws {
        let world = World()
        let certificate = try certify(world, paths: ["/p/A.swift"], aliases: ["/tmp/x": "/private/tmp/x"],
                                      texts: ["/d/list"], regularFiles: ["/t/plugin"])
        let original = (world.entries, world.resolutions, world.regularFiles, world.texts)
        func reset() { (world.entries, world.resolutions, world.regularFiles, world.texts) = original }

        world.entries["/p/A.swift"] = nil
        #expect(world.revalidate(certificate) == .stale("prefix-missing"))
        reset()
        world.resolutions["/tmp"] = "/private/var/tmp"
        #expect(world.revalidate(certificate) == .stale("link-resolution"))
        reset()
        world.texts["/d/list"]!.changedNS += 1
        #expect(world.revalidate(certificate) == .stale("text"))
        reset()
        world.regularFiles = []
        #expect(world.revalidate(certificate) == .stale("regular-file"))
        reset()
        #expect(world.revalidate(certificate) == .valid(refreshed: nil))
    }

    @Test
    func unidentifiedTextOrRacingCreationIsNotCertified() throws {
        let world = World()
        world.add("/p/A.swift")
        let recorder = world.recorder()
        _ = recorder.text("/d/missing") { _ in "x" }
        _ = recorder.canonical("/p/A.swift")
        #expect(recorder.certificate(plan: plan, workingDirectory: "/w", references: []) == nil)

        // A path that did not exist when identities were captured but resolved afterwards.
        let racing = World()
        racing.resolutions["/r/New.swift"] = "/r/New.swift"
        let raceRecorder = racing.recorder()
        _ = raceRecorder.canonical("/r/New.swift")
        #expect(raceRecorder.certificate(plan: plan, workingDirectory: "/w", references: []) == nil)
    }
}
