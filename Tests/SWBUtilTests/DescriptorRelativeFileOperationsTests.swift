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
