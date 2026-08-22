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

    #if canImport(System)
        package import System
    #else
        package import SystemPackage
    #endif

    /// A deliberately small Darwin boundary for operating on one path component
    /// relative to an already-open directory without following symbolic links.
    ///
    /// The primitive operations accept only one component, so a caller cannot
    /// accidentally escape a descriptor-relative boundary. The absolute snapshot
    /// operation below performs the complete anchored traversal itself.
    package enum DescriptorRelativeFileOperations {
        private static let snapshotChunkByteCount = 64 * 1024

        package enum NodeType: Sendable, Equatable {
            case regularFile
            case directory
            case symbolicLink
            case other
        }

        package struct Metadata: Sendable, Equatable {
            package let device: UInt64
            package let inode: UInt64
            package let linkCount: UInt64
            package let byteCount: Int64
            package let permissions: UInt16
            package let modificationTimeSeconds: Int64
            package let modificationTimeNanoseconds: Int64
            package let changeTimeSeconds: Int64
            package let changeTimeNanoseconds: Int64
            package let type: NodeType
        }

        package struct RegularFileSnapshot: Sendable, Equatable {
            package let metadata: Metadata
            package let digest: ByteString
        }

        /// Events exposed only to make descriptor anchoring, cancellation, and
        /// metadata drift deterministic in focused tests.
        package enum SnapshotTestingEvent: Sendable, Equatable {
            case leafOpened
            case chunkHashed(index: Int)
        }

        package enum OperationError: Error, Sendable, Equatable {
            case invalidAbsolutePath
            case invalidComponent(String)
            case fileChanged(before: Metadata, after: Metadata)
            case outputAccessPlanClosed
            case scrubFailed
            case unexpectedEndOfFile(expectedByteCount: Int64, actualByteCount: Int64)
            case unexpectedNodeType(expected: NodeType, actual: NodeType)
            case unexpectedSystemCallResult(CInt)
        }

        package enum OutputAccessPlanSelection {
            case descriptor(OutputAccessPlan)
            case pseudoFileSystemFallback
            case unsupportedFileSystem
        }

        /// A Sendable admission record containing only normalized paths and
        /// bounded identities. Descriptor ownership is confined to synchronous
        /// sessions so raw handles never cross an `await` boundary.
        package struct OutputAccessPlan: Sendable {
            package enum LeafExpectation: Sendable {
                case admitted
                case absent
                case unchecked
            }

            fileprivate struct Entry: Sendable {
                let path: Path
                let leaf: String
                let parentMetadata: Metadata
                let admittedLeafMetadata: Metadata?
            }

            fileprivate let entries: [Entry]

            fileprivate init(paths: [Path], isCancelled: () -> Bool) throws {
                guard !paths.isEmpty, Set(paths).count == paths.count else {
                    throw OperationError.invalidAbsolutePath
                }
                let componentGroups = try paths.map(absoluteComponents(of:))
                var admittedEntries: [Entry] = []
                admittedEntries.reserveCapacity(paths.count)
                for (path, components) in zip(paths, componentGroups) {
                    try checkCancellation(isCancelled)
                    let parent = try openParentDirectory(components: components, isCancelled: isCancelled)
                    defer { try? parent.close() }
                    let leaf = components[components.count - 1]
                    let admittedLeafMetadata: Metadata?
                    do {
                        let metadata = try metadata(of: leaf, relativeTo: parent)
                        guard metadata.type == .regularFile else {
                            throw OperationError.unexpectedNodeType(expected: .regularFile, actual: metadata.type)
                        }
                        admittedLeafMetadata = metadata
                    } catch let error as Errno where error == .noSuchFileOrDirectory {
                        admittedLeafMetadata = nil
                    }
                    admittedEntries.append(
                        Entry(
                            path: path,
                            leaf: leaf,
                            parentMetadata: try metadata(of: parent),
                            admittedLeafMetadata: admittedLeafMetadata
                        ))
                    try checkCancellation(isCancelled)
                }
                entries = admittedEntries
            }

            package var count: Int {
                entries.count
            }

            package var paths: [Path] {
                entries.map(\.path)
            }

            package func openSession(
                leafExpectation: LeafExpectation,
                isCancelled: () -> Bool = { false }
            ) throws -> OutputAccessSession {
                try OutputAccessSession(
                    plan: self,
                    leafExpectation: leafExpectation,
                    isCancelled: isCancelled
                )
            }

            package func revalidateCurrentNamespace(
                leafExpectation: LeafExpectation,
                isCancelled: () -> Bool = { false }
            ) throws {
                let session = try openSession(leafExpectation: leafExpectation, isCancelled: isCancelled)
                session.close()
            }
        }

        /// A synchronous descriptor scope for one admitted plan. This class is
        /// deliberately non-Sendable and must not escape across an `await`.
        package final class OutputAccessSession {
            private struct Entry {
                let plan: OutputAccessPlan.Entry
                let parent: FileDescriptor
                var replayLeafMetadata: Metadata?
            }

            private var entries: [Entry]
            private var isClosed = false

            fileprivate init(
                plan: OutputAccessPlan,
                leafExpectation: OutputAccessPlan.LeafExpectation,
                isCancelled: () -> Bool
            ) throws {
                var openedEntries: [Entry] = []
                openedEntries.reserveCapacity(plan.entries.count)
                do {
                    for admitted in plan.entries {
                        try checkCancellation(isCancelled)
                        let components = try absoluteComponents(of: admitted.path)
                        let parent = try openParentDirectory(components: components, isCancelled: isCancelled)
                        do {
                            let currentParent = try metadata(of: parent)
                            guard currentParent.device == admitted.parentMetadata.device,
                                currentParent.inode == admitted.parentMetadata.inode,
                                currentParent.type == .directory
                            else {
                                throw OperationError.fileChanged(before: admitted.parentMetadata, after: currentParent)
                            }
                            switch leafExpectation {
                            case .admitted:
                                let currentLeaf = try Self.existingMetadata(leaf: admitted.leaf, parent: parent)
                                guard currentLeaf == admitted.admittedLeafMetadata else {
                                    throw OperationError.scrubFailed
                                }
                            case .absent:
                                guard try Self.existingMetadata(leaf: admitted.leaf, parent: parent) == nil else {
                                    throw OperationError.scrubFailed
                                }
                            case .unchecked:
                                break
                            }
                            openedEntries.append(Entry(plan: admitted, parent: parent, replayLeafMetadata: nil))
                        } catch {
                            try? parent.close()
                            throw error
                        }
                        try checkCancellation(isCancelled)
                    }
                    entries = openedEntries
                } catch {
                    for entry in openedEntries {
                        try? entry.parent.close()
                    }
                    throw error
                }
            }

            deinit {
                close()
            }

            package var count: Int { entries.count }

            package var parentDescriptorRawValuesForTesting: [CInt] {
                entries.map { $0.parent.rawValue }
            }

            package func scrubAdmittedOutputs(isCancelled: () -> Bool = { false }) throws {
                try ensureOpen()
                var failed = false
                var cancellationObserved = isCancelled() || Task.isCancelled
                for entry in entries {
                    cancellationObserved = cancellationObserved || isCancelled() || Task.isCancelled
                    let current: Metadata?
                    do {
                        current = try Self.existingMetadata(leaf: entry.plan.leaf, parent: entry.parent)
                    } catch {
                        failed = true
                        continue
                    }
                    switch (entry.plan.admittedLeafMetadata, current) {
                    case (nil, nil), (.some, nil):
                        break
                    case (nil, .some):
                        failed = true
                    case (.some(let admitted), .some(let existing)) where admitted == existing:
                        if !unlinkAndRequireMissing(entry) { failed = true }
                    case (.some, .some):
                        failed = true
                    }
                    cancellationObserved = cancellationObserved || isCancelled() || Task.isCancelled
                }
                if failed { throw OperationError.scrubFailed }
                if cancellationObserved { throw CancellationError() }
            }

            /// Captures the nodes produced by replay before manifesting or scrub.
            /// Missing nodes remain missing; static special nodes fail closed.
            package func captureReplayOutputs() throws {
                try ensureOpen()
                for index in entries.indices {
                    do {
                        let current = try metadata(of: entries[index].plan.leaf, relativeTo: entries[index].parent)
                        guard current.type == .regularFile else {
                            throw OperationError.unexpectedNodeType(expected: .regularFile, actual: current.type)
                        }
                        entries[index].replayLeafMetadata = current
                    } catch let error as Errno where error == .noSuchFileOrDirectory {
                        entries[index].replayLeafMetadata = nil
                    }
                }
            }

            package func snapshotReplayedOutput(
                at index: Int,
                isCancelled: () -> Bool = { false }
            ) throws -> RegularFileSnapshot {
                try ensureOpen()
                let entry = entries[index]
                guard let expected = entry.replayLeafMetadata else {
                    throw Errno.noSuchFileOrDirectory
                }
                let snapshot = try snapshotRegularFile(
                    entry.plan.leaf,
                    relativeTo: entry.parent,
                    isCancelled: isCancelled
                )
                guard snapshot.metadata == expected else {
                    throw OperationError.fileChanged(before: expected, after: snapshot.metadata)
                }
                return snapshot
            }

            package func snapshotCurrentOutput(
                at index: Int,
                isCancelled: () -> Bool = { false }
            ) throws -> RegularFileSnapshot {
                try ensureOpen()
                let entry = entries[index]
                return try snapshotRegularFile(
                    entry.plan.leaf,
                    relativeTo: entry.parent,
                    isCancelled: isCancelled
                )
            }

            package func scrubReplayOutputs(isCancelled: () -> Bool = { false }) throws {
                try ensureOpen()
                var failed = false
                var cancellationObserved = isCancelled() || Task.isCancelled
                for entry in entries {
                    cancellationObserved = cancellationObserved || isCancelled() || Task.isCancelled
                    let current: Metadata?
                    do {
                        current = try Self.existingMetadata(leaf: entry.plan.leaf, parent: entry.parent)
                    } catch {
                        failed = true
                        continue
                    }
                    switch (entry.replayLeafMetadata, current) {
                    case (nil, nil), (.some, nil):
                        break
                    case (nil, .some):
                        failed = true
                    case (.some(let replayed), .some(let existing)) where replayed == existing:
                        if !unlinkAndRequireMissing(entry) {
                            failed = true
                        }
                    case (.some, .some):
                        failed = true
                    }
                    cancellationObserved = cancellationObserved || isCancelled() || Task.isCancelled
                }
                if failed { throw OperationError.scrubFailed }
                if cancellationObserved { throw CancellationError() }
            }

            package func close() {
                guard !isClosed else { return }
                isClosed = true
                for entry in entries {
                    try? entry.parent.close()
                }
            }

            private func ensureOpen() throws {
                if isClosed { throw OperationError.outputAccessPlanClosed }
            }

            private static func existingMetadata(leaf: String, parent: FileDescriptor) throws -> Metadata? {
                do {
                    return try metadata(of: leaf, relativeTo: parent)
                } catch let error as Errno where error == .noSuchFileOrDirectory {
                    return nil
                }
            }

            private func unlinkAndRequireMissing(_ entry: Entry) -> Bool {
                do {
                    try unlink(entry.plan.leaf, relativeTo: entry.parent)
                    return try Self.existingMetadata(leaf: entry.plan.leaf, parent: entry.parent) == nil
                } catch {
                    return false
                }
            }
        }

        package static func makeOutputAccessPlan(
            paths: [Path],
            fs: any FSProxy,
            isCancelled: () -> Bool = { false }
        ) throws -> OutputAccessPlanSelection {
            if fs is PseudoFS {
                return .pseudoFileSystemFallback
            }
            guard fs is LocalFS else {
                return .unsupportedFileSystem
            }
            return .descriptor(try OutputAccessPlan(paths: paths, isCancelled: isCancelled))
        }

        /// Takes a descriptor-anchored snapshot of one absolute regular file.
        /// Every ancestor is opened relative to the previously opened directory,
        /// and symbolic links are rejected at every component. The initial file
        /// size is also the read budget, so concurrent growth cannot make this
        /// operation unbounded.
        package static func snapshotRegularFile(
            at path: Path,
            isCancelled: () -> Bool = { false },
            testingHook: ((SnapshotTestingEvent, FileDescriptor) throws -> Void)? = nil
        ) throws -> RegularFileSnapshot {
            let components = try absoluteComponents(of: path)
            let parent = try openParentDirectory(components: components, isCancelled: isCancelled)
            defer { try? parent.close() }
            return try snapshotRegularFile(
                components[components.count - 1],
                relativeTo: parent,
                isCancelled: isCancelled,
                testingHook: testingHook
            )
        }

        package static func snapshotRegularFile(
            _ component: String,
            relativeTo directory: FileDescriptor,
            isCancelled: () -> Bool = { false },
            testingHook: ((SnapshotTestingEvent, FileDescriptor) throws -> Void)? = nil
        ) throws -> RegularFileSnapshot {
            let leaf = try openRegularFile(component, relativeTo: directory)
            defer { try? leaf.close() }
            try testingHook?(.leafOpened, leaf)

            let before = try metadata(of: leaf)
            guard before.type == .regularFile else {
                throw OperationError.unexpectedNodeType(expected: .regularFile, actual: before.type)
            }

            let hash = SHA256Context()
            var remainingByteCount = before.byteCount
            var hashedByteCount: Int64 = 0
            var chunkIndex = 0
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: snapshotChunkByteCount, alignment: 1)
            defer { buffer.deallocate() }

            while remainingByteCount > 0 {
                try checkCancellation(isCancelled)
                let requestedByteCount = Int(min(Int64(snapshotChunkByteCount), remainingByteCount))
                let readByteCount = try retryingSyscall {
                    CInt(Darwin.read(leaf.rawValue, buffer.baseAddress, requestedByteCount))
                }
                guard readByteCount > 0 else { break }

                let count = Int(readByteCount)
                hash.add(bytes: ByteString(buffer.prefix(count)))
                hashedByteCount += Int64(count)
                remainingByteCount -= Int64(count)
                try testingHook?(.chunkHashed(index: chunkIndex), leaf)
                try checkCancellation(isCancelled)
                chunkIndex += 1
            }

            try checkCancellation(isCancelled)
            let after = try metadata(of: leaf)
            guard before == after else {
                throw OperationError.fileChanged(before: before, after: after)
            }
            guard remainingByteCount == 0 else {
                throw OperationError.unexpectedEndOfFile(
                    expectedByteCount: before.byteCount,
                    actualByteCount: hashedByteCount
                )
            }
            try checkCancellation(isCancelled)
            return RegularFileSnapshot(metadata: after, digest: hash.signature)
        }

        package static func openDirectory(
            _ component: String,
            relativeTo directory: FileDescriptor
        ) throws -> FileDescriptor {
            try open(
                component,
                relativeTo: directory,
                options: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                expectedType: .directory
            )
        }

        package static func openRegularFile(
            _ component: String,
            relativeTo directory: FileDescriptor
        ) throws -> FileDescriptor {
            try open(
                component,
                relativeTo: directory,
                options: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                expectedType: .regularFile
            )
        }

        /// Returns metadata for the named node itself, never its symlink target.
        package static func metadata(
            of component: String,
            relativeTo directory: FileDescriptor
        ) throws -> Metadata {
            try validate(component: component)
            var status = Darwin.stat()
            _ = try component.withCString { name in
                try retryingSyscall {
                    Darwin.fstatat(directory.rawValue, name, &status, AT_SYMLINK_NOFOLLOW)
                }
            }
            return metadata(from: status)
        }

        package static func metadata(of descriptor: FileDescriptor) throws -> Metadata {
            var status = Darwin.stat()
            _ = try retryingSyscall {
                Darwin.fstat(descriptor.rawValue, &status)
            }
            return metadata(from: status)
        }

        /// Removes the named node itself. `unlinkat` does not follow a leaf symlink,
        /// and the fixed zero flags deliberately refuse to remove directories.
        package static func unlink(
            _ component: String,
            relativeTo directory: FileDescriptor
        ) throws {
            try validate(component: component)
            _ = try component.withCString { name in
                try retryingSyscall {
                    Darwin.unlinkat(directory.rawValue, name, 0)
                }
            }
        }

        /// Shared EINTR boundary for the descriptor-relative POSIX calls above.
        /// The injected errno provider keeps retry behavior deterministic in tests.
        package static func retryingSyscall(
            _ operation: () -> CInt,
            errnoProvider: () -> CInt = { Darwin.errno }
        ) throws -> CInt {
            while true {
                let result = operation()
                if result >= 0 {
                    return result
                }
                guard result == -1 else {
                    throw OperationError.unexpectedSystemCallResult(result)
                }
                let error = Errno(rawValue: errnoProvider())
                if error == .interrupted {
                    continue
                }
                throw error
            }
        }

        private static func open(
            _ component: String,
            relativeTo directory: FileDescriptor,
            options: CInt,
            expectedType: NodeType
        ) throws -> FileDescriptor {
            try validate(component: component)
            let rawDescriptor = try component.withCString { name in
                try retryingSyscall {
                    Darwin.openat(directory.rawValue, name, options)
                }
            }
            let descriptor = FileDescriptor(rawValue: rawDescriptor)
            do {
                let actualType = try metadata(of: descriptor).type
                guard actualType == expectedType else {
                    throw OperationError.unexpectedNodeType(expected: expectedType, actual: actualType)
                }
                return descriptor
            } catch {
                try? descriptor.close()
                throw error
            }
        }

        private static func openRootDirectory() throws -> FileDescriptor {
            let rawDescriptor = try "/".withCString { path in
                try retryingSyscall {
                    Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            let descriptor = FileDescriptor(rawValue: rawDescriptor)
            do {
                let actualType = try metadata(of: descriptor).type
                guard actualType == .directory else {
                    throw OperationError.unexpectedNodeType(expected: .directory, actual: actualType)
                }
                return descriptor
            } catch {
                try? descriptor.close()
                throw error
            }
        }

        private static func openParentDirectory(
            components: [String],
            isCancelled: () -> Bool
        ) throws -> FileDescriptor {
            try checkCancellation(isCancelled)
            var current = try openRootDirectory()
            do {
                try checkCancellation(isCancelled)
                for component in components.dropLast() {
                    let next = try openDirectory(component, relativeTo: current)
                    try? current.close()
                    current = next
                    try checkCancellation(isCancelled)
                }
                return current
            } catch {
                try? current.close()
                throw error
            }
        }

        private static func checkCancellation(_ isCancelled: () -> Bool) throws {
            if isCancelled() || Task.isCancelled {
                throw CancellationError()
            }
        }

        private static func absoluteComponents(of path: Path) throws -> [String] {
            guard path.isAbsolute,
                !path.isRoot,
                path == path.normalize(),
                !path.str.hasSuffix("/"),
                !path.str.utf8.contains(0)
            else {
                throw OperationError.invalidAbsolutePath
            }

            let components = path.str.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw OperationError.invalidAbsolutePath
            }
            return components
        }

        private static func validate(component: String) throws {
            guard !component.isEmpty,
                component != ".",
                component != "..",
                !component.contains("/"),
                !component.utf8.contains(0)
            else {
                throw OperationError.invalidComponent(component)
            }
        }

        private static func metadata(from status: Darwin.stat) -> Metadata {
            let fileType = status.st_mode & S_IFMT
            let type: NodeType
            switch fileType {
            case S_IFREG:
                type = .regularFile
            case S_IFDIR:
                type = .directory
            case S_IFLNK:
                type = .symbolicLink
            default:
                type = .other
            }
            return Metadata(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                linkCount: UInt64(status.st_nlink),
                byteCount: status.st_size,
                permissions: UInt16(status.st_mode & 0o7777),
                modificationTimeSeconds: Int64(status.st_mtimespec.tv_sec),
                modificationTimeNanoseconds: Int64(status.st_mtimespec.tv_nsec),
                changeTimeSeconds: Int64(status.st_ctimespec.tv_sec),
                changeTimeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
                type: type
            )
        }
    }

    @available(*, unavailable)
    extension DescriptorRelativeFileOperations.OutputAccessSession: Sendable {}
#endif
