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

package enum LocalFileSystemOutputAccessPlanSelection {
    #if canImport(Darwin)
        case descriptor(DescriptorRelativeFileOperations.OutputAccessPlan)
    #endif
    case compatibilityFallback
    case unsupportedFileSystem
}

/// Cross-host facade for selecting the descriptor backend without exposing
/// SWBUtil's concrete LocalFS/PseudoFS implementations to clients.
package func makeLocalFileSystemOutputAccessPlan(
    paths: [Path],
    fs: any FSProxy,
    isCancelled: () -> Bool = { false }
) throws -> LocalFileSystemOutputAccessPlanSelection {
    #if canImport(Darwin)
        switch try DescriptorRelativeFileOperations.makeOutputAccessPlan(
            paths: paths,
            fs: fs,
            isCancelled: isCancelled
        ) {
        case .descriptor(let plan):
            return .descriptor(plan)
        case .pseudoFileSystemFallback:
            return .compatibilityFallback
        case .unsupportedFileSystem:
            return .unsupportedFileSystem
        }
    #else
        if fs is LocalFS || fs is PseudoFS {
            return .compatibilityFallback
        }
        return .unsupportedFileSystem
    #endif
}

/// Keeps concrete filesystem type checks inside SWBUtil while allowing clients
/// to reject supplied descriptor plans for pseudo or custom filesystems.
package func supportsDescriptorOutputAccessPlan(fs: any FSProxy) -> Bool {
    #if canImport(Darwin)
        return fs is LocalFS
    #else
        return false
    #endif
}
