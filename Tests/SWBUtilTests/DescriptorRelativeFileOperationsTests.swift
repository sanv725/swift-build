//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if canImport(Darwin)
    import Darwin
    import Foundation
    import Testing

    import SWBTestSupport
    @_spi(TestSupport) import SWBUtil

    #if canImport(System)
        import System
    #else
        import SystemPackage
    #endif

    @Suite(.requireHostOS(.macOS))
    fileprivate struct DescriptorRelativeFileOperationsTests {
        @Test
        func rejectsNonComponentPaths() throws {
            try withTemporaryDirectory { temporaryDirectory in
                let directory = try openDirectory(temporaryDirectory)
                defer { try? directory.close() }

                for invalid in ["", ".", "..", "nested/file", "nul\0byte"] {
                    #expect(throws: DescriptorRelativeFileOperations.OperationError.invalidComponent(invalid)) {
                        _ = try DescriptorRelativeFileOperations.metadata(of: invalid, relativeTo: directory)
                    }
                }
            }
        }

        @Test
        func noFollowOperationsInspectAndRemoveTheSymlinkNode() throws {
            try withTemporaryDirectory { temporaryDirectory in
                let victim = temporaryDirectory.join("victim")
                let link = temporaryDirectory.join("link")
                let linkedDirectory = temporaryDirectory.join("linked-directory")
                let realDirectory = temporaryDirectory.join("real-directory")
                try localFS.write(victim, contents: ByteString(encodingAsUTF8: "victim"))
                try localFS.createDirectory(realDirectory)
                try localFS.symlink(link, target: victim)
                try localFS.symlink(linkedDirectory, target: realDirectory)

                let directory = try openDirectory(temporaryDirectory)
                defer { try? directory.close() }

                #expect(try DescriptorRelativeFileOperations.metadata(of: link.basename, relativeTo: directory).type == .symbolicLink)
                #expect(throws: Errno.tooManySymbolicLinkLevels) {
                    _ = try DescriptorRelativeFileOperations.openRegularFile(link.basename, relativeTo: directory)
                }
                #expect(throws: (any Error).self) {
                    _ = try DescriptorRelativeFileOperations.openDirectory(linkedDirectory.basename, relativeTo: directory)
                }
                #expect(
                    throws: DescriptorRelativeFileOperations.OperationError.unexpectedNodeType(
                        expected: .regularFile,
                        actual: .directory
                    )
                ) {
                    _ = try DescriptorRelativeFileOperations.openRegularFile(realDirectory.basename, relativeTo: directory)
                }

                try DescriptorRelativeFileOperations.unlink(link.basename, relativeTo: directory)
                #expect(!localFS.isSymlink(link))
                #expect(try localFS.read(victim) == ByteString(encodingAsUTF8: "victim"))
            }
        }

        @Test
        func openedAncestorRemainsAnchoredAfterPathReplacement() throws {
            try withTemporaryDirectory { temporaryDirectory in
                let originalDirectory = temporaryDirectory.join("ancestor")
                let movedDirectory = temporaryDirectory.join("ancestor-moved")
                let originalLeaf = originalDirectory.join("leaf")
                try localFS.createDirectory(originalDirectory)
                try localFS.write(originalLeaf, contents: ByteString(encodingAsUTF8: "original"))

                let root = try openDirectory(temporaryDirectory)
                defer { try? root.close() }
                let anchoredAncestor = try DescriptorRelativeFileOperations.openDirectory(originalDirectory.basename, relativeTo: root)
                defer { try? anchoredAncestor.close() }
                let anchoredIdentity = try DescriptorRelativeFileOperations.metadata(of: anchoredAncestor)

                try localFS.move(originalDirectory, to: movedDirectory)
                try localFS.createDirectory(originalDirectory)
                try localFS.write(originalDirectory.join("leaf"), contents: ByteString(encodingAsUTF8: "replacement"))

                let replacementAncestor = try DescriptorRelativeFileOperations.openDirectory(originalDirectory.basename, relativeTo: root)
                defer { try? replacementAncestor.close() }
                let replacementIdentity = try DescriptorRelativeFileOperations.metadata(of: replacementAncestor)
                #expect(anchoredIdentity.device != replacementIdentity.device || anchoredIdentity.inode != replacementIdentity.inode)

                let anchoredLeaf = try DescriptorRelativeFileOperations.openRegularFile("leaf", relativeTo: anchoredAncestor)
                defer { try? anchoredLeaf.close() }
                #expect(try readAll(anchoredLeaf) == ByteString(encodingAsUTF8: "original"))

                let replacementLeaf = try DescriptorRelativeFileOperations.openRegularFile("leaf", relativeTo: replacementAncestor)
                defer { try? replacementLeaf.close() }
                #expect(try readAll(replacementLeaf) == ByteString(encodingAsUTF8: "replacement"))
            }
        }

        @Test
        func missingNodesRemainMissingForEveryPrimitive() throws {
            try withTemporaryDirectory { temporaryDirectory in
                let directory = try openDirectory(temporaryDirectory)
                defer { try? directory.close() }

                #expect(throws: Errno.noSuchFileOrDirectory) {
                    _ = try DescriptorRelativeFileOperations.metadata(of: "missing", relativeTo: directory)
                }
                #expect(throws: Errno.noSuchFileOrDirectory) {
                    _ = try DescriptorRelativeFileOperations.openRegularFile("missing", relativeTo: directory)
                }
                #expect(throws: Errno.noSuchFileOrDirectory) {
                    try DescriptorRelativeFileOperations.unlink("missing", relativeTo: directory)
                }
            }
        }

        @Test
        func metadataReportsPermissionChangesByNameAndDescriptor() throws {
            try withTemporaryDirectory { temporaryDirectory in
                let leaf = temporaryDirectory.join("leaf")
                try localFS.write(leaf, contents: ByteString(encodingAsUTF8: "contents"))
                try localFS.setFilePermissions(leaf, permissions: 0o600)

                let directory = try openDirectory(temporaryDirectory)
                defer { try? directory.close() }
                let descriptor = try DescriptorRelativeFileOperations.openRegularFile(leaf.basename, relativeTo: directory)
                defer { try? descriptor.close() }

                #expect(try DescriptorRelativeFileOperations.metadata(of: leaf.basename, relativeTo: directory).permissions == 0o600)
                #expect(try DescriptorRelativeFileOperations.metadata(of: descriptor).permissions == 0o600)

                try localFS.setFilePermissions(leaf, permissions: 0o640)
                #expect(try DescriptorRelativeFileOperations.metadata(of: leaf.basename, relativeTo: directory).permissions == 0o640)
                #expect(try DescriptorRelativeFileOperations.metadata(of: descriptor).permissions == 0o640)
            }
        }

        @Test
        func regularFileOpenRejectsFIFOWithoutWaitingForAWriter() throws {
            try withTemporaryDirectory { temporaryDirectory in
                let fifo = temporaryDirectory.join("fifo")
                try #require(Darwin.mkfifo(fifo.str, 0o600) == 0)

                let directory = try openDirectory(temporaryDirectory)
                defer { try? directory.close() }
                #expect(try DescriptorRelativeFileOperations.metadata(of: fifo.basename, relativeTo: directory).type == .other)
                #expect(
                    throws: DescriptorRelativeFileOperations.OperationError.unexpectedNodeType(
                        expected: .regularFile,
                        actual: .other
                    )
                ) {
                    _ = try DescriptorRelativeFileOperations.openRegularFile(fifo.basename, relativeTo: directory)
                }
            }
        }

        @Test
        func snapshotsMultipleChunksWithDigestParity() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let leaf = temporaryDirectory.join("leaf")
                let contents = ByteString((0..<(64 * 1024 * 2 + 17)).map { UInt8(truncatingIfNeeded: $0) })
                try localFS.write(leaf, contents: contents)

                var chunkCount = 0
                let snapshot = try DescriptorRelativeFileOperations.snapshotRegularFile(
                    at: leaf,
                    testingHook: { event, _ in
                        if case .chunkHashed = event {
                            chunkCount += 1
                        }
                    }
                )
                let expectedHash = SHA256Context()
                expectedHash.add(bytes: contents)

                #expect(chunkCount == 3)
                #expect(snapshot.metadata.type == .regularFile)
                #expect(snapshot.metadata.byteCount == Int64(contents.count))
                #expect(snapshot.digest == expectedHash.signature)
            }
        }

        @Test
        func snapshotPreservesMidStreamCancellation() async throws {
            try await withTemporaryDirectory { (temporaryDirectory: Path) in
                let leaf = temporaryDirectory.join("leaf")
                try localFS.write(
                    leaf,
                    contents: ByteString((0..<(64 * 1024 * 2)).map { UInt8(truncatingIfNeeded: $0) })
                )
                let firstChunkHashed = WaitCondition()
                let allowCancellationCheck = DispatchSemaphore(value: 0)
                let snapshotTask = Task.detached {
                    try DescriptorRelativeFileOperations.snapshotRegularFile(
                        at: leaf,
                        testingHook: { event, _ in
                            if event == .chunkHashed(index: 0) {
                                firstChunkHashed.signal()
                                allowCancellationCheck.wait()
                            }
                        }
                    )
                }

                await firstChunkHashed.wait()
                snapshotTask.cancel()
                allowCancellationCheck.signal()
                await #expect(throws: CancellationError.self) {
                    try await snapshotTask.value
                }
            }
        }

        @Test
        func snapshotPreservesCallbackOnlyMidStreamCancellation() throws {
            try withTemporaryDirectory { temporaryDirectory in
                let leaf = temporaryDirectory.join("leaf")
                try localFS.write(
                    leaf,
                    contents: ByteString((0..<(64 * 1024 * 2)).map { UInt8(truncatingIfNeeded: $0) })
                )
                var cancelled = false

                #expect(throws: CancellationError.self) {
                    _ = try DescriptorRelativeFileOperations.snapshotRegularFile(
                        at: leaf,
                        isCancelled: { cancelled },
                        testingHook: { event, _ in
                            if event == .chunkHashed(index: 0) {
                                cancelled = true
                            }
                        }
                    )
                }
                #expect(cancelled)
                #expect(!Task.isCancelled)
            }
        }

        @Test
        func snapshotRejectsAncestorSymlinks() throws {
            try withTemporaryDirectory { temporaryDirectory in
                let realAncestor = temporaryDirectory.join("real")
                let linkedAncestor = temporaryDirectory.join("linked")
                try localFS.createDirectory(realAncestor)
                try localFS.write(realAncestor.join("leaf"), contents: ByteString(encodingAsUTF8: "contents"))
                try localFS.symlink(linkedAncestor, target: realAncestor)

                #expect(throws: (any Error).self) {
                    _ = try DescriptorRelativeFileOperations.snapshotRegularFile(at: linkedAncestor.join("leaf"))
                }
            }
        }

        @Test
        func snapshotLeafRemainsAnchoredAfterPathReplacement() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let leaf = temporaryDirectory.join("leaf")
                let movedLeaf = temporaryDirectory.join("moved-leaf")
                let replacement = temporaryDirectory.join("replacement")
                let originalContents = ByteString(encodingAsUTF8: "original contents")
                let replacementContents = ByteString(encodingAsUTF8: "replacement contents")
                try localFS.write(leaf, contents: originalContents)
                try localFS.write(replacement, contents: replacementContents)

                let snapshot = try DescriptorRelativeFileOperations.snapshotRegularFile(
                    at: leaf,
                    testingHook: { event, _ in
                        guard event == .leafOpened else { return }
                        try localFS.move(leaf, to: movedLeaf)
                        try localFS.move(replacement, to: leaf)
                    }
                )
                let expectedHash = SHA256Context()
                expectedHash.add(bytes: originalContents)

                #expect(snapshot.metadata.byteCount == Int64(originalContents.count))
                #expect(snapshot.digest == expectedHash.signature)
                #expect(try localFS.read(leaf) == replacementContents)
            }
        }

        @Test
        func snapshotRejectsBeforeAfterPermissionDrift() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let leaf = temporaryDirectory.join("leaf")
                try localFS.write(
                    leaf,
                    contents: ByteString((0..<(64 * 1024 + 1)).map { UInt8(truncatingIfNeeded: $0) })
                )
                try localFS.setFilePermissions(leaf, permissions: 0o600)

                do {
                    _ = try DescriptorRelativeFileOperations.snapshotRegularFile(
                        at: leaf,
                        testingHook: { event, descriptor in
                            guard event == .chunkHashed(index: 0) else { return }
                            try #require(Darwin.fchmod(descriptor.rawValue, 0o640) == 0)
                        }
                    )
                    Issue.record("expected permission drift to reject the snapshot")
                } catch let error as DescriptorRelativeFileOperations.OperationError {
                    guard case .fileChanged(let before, let after) = error else {
                        Issue.record("unexpected snapshot error: \(error)")
                        return
                    }
                    #expect(before.permissions == 0o600)
                    #expect(after.permissions == 0o640)
                    #expect(before.device == after.device)
                    #expect(before.inode == after.inode)
                }
            }
        }

        @Test
        func snapshotRejectsSameSizeInPlaceRewrite() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let leaf = temporaryDirectory.join("leaf")
                let byteCount = 64 * 1024 + 1
                let originalContents = ByteString((0..<byteCount).map { UInt8(truncatingIfNeeded: $0) })
                let replacementContents = ByteString((0..<byteCount).map { UInt8(truncatingIfNeeded: ~$0) })
                try localFS.write(leaf, contents: originalContents)
                try localFS.setFilePermissions(leaf, permissions: 0o600)

                do {
                    _ = try DescriptorRelativeFileOperations.snapshotRegularFile(
                        at: leaf,
                        testingHook: { event, descriptor in
                            guard event == .chunkHashed(index: 0) else { return }
                            try localFS.write(leaf, contents: replacementContents)
                            let times = [
                                timespec(tv_sec: 946_684_800, tv_nsec: 123_456_789),
                                timespec(tv_sec: 946_684_800, tv_nsec: 123_456_789),
                            ]
                            try #require(times.withUnsafeBufferPointer { Darwin.futimens(descriptor.rawValue, $0.baseAddress) } == 0)
                        }
                    )
                    Issue.record("expected a same-size rewrite to reject the snapshot")
                } catch let error as DescriptorRelativeFileOperations.OperationError {
                    guard case .fileChanged(let before, let after) = error else {
                        Issue.record("unexpected snapshot error: \(error)")
                        return
                    }
                    #expect(before.byteCount == after.byteCount)
                    #expect(before.permissions == after.permissions)
                    #expect(before.device == after.device)
                    #expect(before.inode == after.inode)
                    #expect(
                        before.modificationTimeSeconds != after.modificationTimeSeconds
                            || before.modificationTimeNanoseconds != after.modificationTimeNanoseconds
                            || before.changeTimeSeconds != after.changeTimeSeconds
                            || before.changeTimeNanoseconds != after.changeTimeNanoseconds
                    )
                }
            }
        }

        @Test
        func snapshotRejectsNonAbsoluteOrNonnormalizedPaths() {
            for invalid in [Path("relative/leaf"), Path("/tmp/../tmp/leaf"), Path("/tmp//leaf"), Path.root] {
                #expect(throws: DescriptorRelativeFileOperations.OperationError.invalidAbsolutePath) {
                    _ = try DescriptorRelativeFileOperations.snapshotRegularFile(at: invalid)
                }
            }
        }

        @Test
        func outputAccessPlanRejectsAncestorSymlinksAndSpecialLeaves() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let realParent = temporaryDirectory.join("real-parent")
                let linkedParent = temporaryDirectory.join("linked-parent")
                try localFS.createDirectory(realParent)
                try localFS.symlink(linkedParent, target: realParent)

                #expect(throws: (any Error).self) {
                    _ = try makeLocalFileSystemOutputAccessPlan(
                        paths: [linkedParent.join("leaf")],
                        fs: localFS
                    )
                }

                let fifo = temporaryDirectory.join("fifo")
                try #require(Darwin.mkfifo(fifo.str, 0o600) == 0)
                #expect(
                    throws: DescriptorRelativeFileOperations.OperationError.unexpectedNodeType(
                        expected: .regularFile,
                        actual: .other
                    )
                ) {
                    _ = try makeLocalFileSystemOutputAccessPlan(paths: [fifo], fs: localFS)
                }
            }
        }

        @Test
        func outputAccessSessionRemainsPinnedAcrossAncestorReplacement() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let parent = temporaryDirectory.join("parent")
                let movedParent = temporaryDirectory.join("moved-parent")
                let output = parent.join("leaf")
                let movedOutput = movedParent.join("leaf")
                let replayedContents = ByteString(encodingAsUTF8: "replayed")
                let replacementContents = ByteString(encodingAsUTF8: "replacement")
                try localFS.createDirectory(parent)

                let plan = try descriptorPlan(paths: [output])
                let session = try plan.openSession(leafExpectation: .admitted)
                defer { session.close() }
                try localFS.write(output, contents: replayedContents)
                try localFS.move(parent, to: movedParent)
                try localFS.createDirectory(parent)
                try localFS.write(output, contents: replacementContents)

                try session.captureReplayOutputs()
                let snapshot = try session.snapshotReplayedOutput(at: 0)
                let expectedHash = SHA256Context()
                expectedHash.add(bytes: replayedContents)
                #expect(snapshot.digest == expectedHash.signature)

                try session.scrubReplayOutputs()
                #expect(!localFS.exists(movedOutput))
                #expect(try localFS.read(output) == replacementContents)
                #expect(throws: (any Error).self) {
                    try plan.revalidateCurrentNamespace(leafExpectation: .unchecked)
                }
            }
        }

        @Test
        func outputAccessSessionPreservesNewAndReplacedAdmittedLeaves() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let absentAtAdmission = temporaryDirectory.join("absent-at-admission")
                let absentPlan = try descriptorPlan(paths: [absentAtAdmission])
                try localFS.write(absentAtAdmission, contents: ByteString(encodingAsUTF8: "new-owner"))
                #expect(throws: DescriptorRelativeFileOperations.OperationError.scrubFailed) {
                    _ = try absentPlan.openSession(leafExpectation: .admitted)
                }
                #expect(try localFS.read(absentAtAdmission).asString == "new-owner")

                let preexisting = temporaryDirectory.join("preexisting")
                let movedPreexisting = temporaryDirectory.join("moved-preexisting")
                try localFS.write(preexisting, contents: ByteString(encodingAsUTF8: "admitted"))
                let preexistingPlan = try descriptorPlan(paths: [preexisting])
                try localFS.move(preexisting, to: movedPreexisting)
                try localFS.write(preexisting, contents: ByteString(encodingAsUTF8: "replacement"))
                #expect(throws: DescriptorRelativeFileOperations.OperationError.scrubFailed) {
                    _ = try preexistingPlan.openSession(leafExpectation: .admitted)
                }
                #expect(try localFS.read(preexisting).asString == "replacement")
            }
        }

        @Test
        func outputAccessRevalidationRejectsLeafRecreatedAfterScrub() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let output = temporaryDirectory.join("leaf")
                let plan = try descriptorPlan(paths: [output])
                let session = try plan.openSession(leafExpectation: .admitted)
                try localFS.write(output, contents: ByteString(encodingAsUTF8: "replayed"))
                try session.captureReplayOutputs()
                try session.scrubReplayOutputs()
                session.close()

                try localFS.write(output, contents: ByteString(encodingAsUTF8: "new-owner"))
                #expect(throws: DescriptorRelativeFileOperations.OperationError.scrubFailed) {
                    try plan.revalidateCurrentNamespace(leafExpectation: .absent)
                }
                #expect(try localFS.read(output).asString == "new-owner")
            }
        }

        @Test
        func outputAccessRevalidationCancelsDuringAncestorWalk() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let first = temporaryDirectory.join("first")
                let second = first.join("second")
                try localFS.createDirectory(second, recursive: true)
                let plan = try descriptorPlan(paths: [second.join("leaf")])
                var cancellationChecks = 0

                #expect(throws: CancellationError.self) {
                    try plan.revalidateCurrentNamespace(
                        leafExpectation: .unchecked,
                        isCancelled: {
                            cancellationChecks += 1
                            return cancellationChecks == 3
                        }
                    )
                }
                #expect(cancellationChecks == 3)

                let session = try plan.openSession(leafExpectation: .admitted)
                let descriptors = session.parentDescriptorRawValuesForTesting
                session.close()
                for descriptor in descriptors {
                    Darwin.errno = 0
                    #expect(Darwin.fcntl(descriptor, F_GETFD) == -1)
                    #expect(Darwin.errno == EBADF)
                }
            }
        }

        @Test
        func outputAccessSessionClosesEveryParentDescriptor() throws {
            try withTemporaryDirectory { (temporaryDirectory: Path) in
                let firstParent = temporaryDirectory.join("first")
                let secondParent = temporaryDirectory.join("second")
                try localFS.createDirectory(firstParent)
                try localFS.createDirectory(secondParent)
                let plan = try descriptorPlan(paths: [firstParent.join("one"), secondParent.join("two")])
                let session = try plan.openSession(leafExpectation: .admitted)
                let descriptors = session.parentDescriptorRawValuesForTesting

                session.close()

                #expect(descriptors.count == 2)
                for descriptor in descriptors {
                    Darwin.errno = 0
                    #expect(Darwin.fcntl(descriptor, F_GETFD) == -1)
                    #expect(Darwin.errno == EBADF)
                }
            }
        }

        @Test
        func retriesOnlyInterruptedSystemCalls() throws {
            var attempts = 0
            let result = try DescriptorRelativeFileOperations.retryingSyscall(
                {
                    attempts += 1
                    return attempts < 3 ? -1 : 41
                },
                errnoProvider: {
                    EINTR
                })
            #expect(result == 41)
            #expect(attempts == 3)

            attempts = 0
            #expect(throws: Errno.permissionDenied) {
                _ = try DescriptorRelativeFileOperations.retryingSyscall(
                    {
                        attempts += 1
                        return -1
                    },
                    errnoProvider: {
                        EACCES
                    })
            }
            #expect(attempts == 1)

            #expect(throws: DescriptorRelativeFileOperations.OperationError.unexpectedSystemCallResult(-2)) {
                _ = try DescriptorRelativeFileOperations.retryingSyscall({ -2 })
            }
        }

        private func openDirectory(_ path: Path) throws -> FileDescriptor {
            try FileDescriptor.open(
                FilePath(path.str),
                .readOnly,
                options: [.directory, .noFollow, .closeOnExec]
            )
        }

        private func descriptorPlan(paths: [Path]) throws -> DescriptorRelativeFileOperations.OutputAccessPlan {
            switch try makeLocalFileSystemOutputAccessPlan(paths: paths, fs: localFS) {
            case .descriptor(let plan):
                return plan
            case .compatibilityFallback, .unsupportedFileSystem:
                throw DescriptorRelativeFileOperations.OperationError.invalidAbsolutePath
            }
        }

        private func readAll(_ descriptor: FileDescriptor) throws -> ByteString {
            var bytes: [UInt8] = []
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 1)
            defer { buffer.deallocate() }
            while true {
                let count = try descriptor.read(into: buffer)
                if count == 0 { break }
                bytes.append(contentsOf: buffer[0..<count])
            }
            return ByteString(bytes)
        }
    }
#endif
