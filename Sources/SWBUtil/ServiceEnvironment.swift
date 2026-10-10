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
import Synchronization

/// The build service's process environment, read once.
///
/// `ProcessInfo.processInfo.environment` rebuilds its dictionary on every call. Per-task reads in hot
/// paths cost about 1.7 s per Reframe edit (SwiftBuildOptimizer C965). The service changes its own
/// environment only during start-up, before any build reads this snapshot.
///
/// A warm session's service outlives requests, so the controls a client would pass per request in the
/// environment of a fresh service (driver plan keys, edited sources) arrive with each build instead
/// (C979). One build runs at a time in a warm session.
package enum ServiceEnvironment {
    private static let process: [String: String] = ProcessInfo.processInfo.environment
    private static let current = SWBMutex<[String: String]?>(nil)

    package static var snapshot: [String: String] {
        current.withLock { $0 } ?? process
    }

    /// Overlay the controls of the build that starts now, or clear them.
    package static func setRequestControls(_ controls: [String: String]?) {
        let merged = controls.map { process.merging($0) { _, request in request } }
        current.withLock { $0 = merged }
    }
}
