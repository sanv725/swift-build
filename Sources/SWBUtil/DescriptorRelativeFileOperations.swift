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
            case unexpectedEndOfFile(expectedByteCount: Int64, actualByteCount: Int64)
            case unexpectedNodeType(expected: NodeType, actual: NodeType)
            case unexpectedSystemCallResult(CInt)
        }

        /// Takes a descriptor-anchored snapshot of one absolute regular file.
        /// Every ancestor is opened relative to the previously opened directory,
        /// and symbolic links are rejected at every component. The initial file
        /// size is also the read budget, so concurrent growth cannot make this
        /// operation unbounded.
        package static func snapshotRegularFile(
            at path: Path,
            testingHook: ((SnapshotTestingEvent, FileDescriptor) throws -> Void)? = nil
        ) throws -> RegularFileSnapshot {
            let components = try absoluteComponents(of: path)
            let root = try openRootDirectory()
            var directories = [root]
            defer {
                for directory in directories.reversed() {
                    try? directory.close()
                }
            }

            for component in components.dropLast() {
                let directory = try openDirectory(component, relativeTo: directories[directories.count - 1])
                directories.append(directory)
            }

            let leaf = try openRegularFile(components[components.count - 1], relativeTo: directories[directories.count - 1])
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
                try Task.checkCancellation()
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
                try Task.checkCancellation()
                chunkIndex += 1
            }

            try Task.checkCancellation()
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
            try Task.checkCancellation()
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
#endif
