//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

/// The build service's process environment, read once.
///
/// `ProcessInfo.processInfo.environment` rebuilds its dictionary on every call. Per-task reads in hot
/// paths cost about 1.7 s per Reframe edit (SwiftBuildOptimizer C965). The service changes its own
/// environment only during start-up, before any build reads this snapshot.
package enum ServiceEnvironment {
    package static let snapshot: [String: String] = ProcessInfo.processInfo.environment
}
