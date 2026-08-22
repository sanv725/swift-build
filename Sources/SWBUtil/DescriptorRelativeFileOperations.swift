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
    /// Higher-level callers remain responsible for opening and retaining every
    /// ancestor directory in order. This type does not accept multi-component or
    /// special-directory paths, so a caller cannot accidentally escape the
    /// descriptor-relative boundary.
    package enum DescriptorRelativeFileOperations {
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
            package let type: NodeType
        }

        package enum OperationError: Error, Sendable, Equatable {
            case invalidComponent(String)
            case unexpectedNodeType(expected: NodeType, actual: NodeType)
            case unexpectedSystemCallResult(CInt)
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
                type: type
            )
        }
    }
#endif
