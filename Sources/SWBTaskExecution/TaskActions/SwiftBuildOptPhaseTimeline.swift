//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Exception
//
//===----------------------------------------------------------------------===//

import Dispatch
import Foundation

/// Opt-in monotonic phase markers used by Swift Build Optimizer experiments.
///
/// The markers stay in the normal task output stream so they inherit Xcode's
/// existing process isolation and require no shared trace file or lock. The
/// environment switch is read only by the build-service process; it is never
/// forwarded to compiler children.
package enum SwiftBuildOptPhaseTimeline {
    package static let environmentVariable = "SWIFT_BUILD_OPT_PHASE_TIMELINE"
    package static let marker = "SWIFT_BUILD_OPT_TIMELINE"

    package static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentVariable] == "1"
    }

    package static var isProcessEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    package static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    package static func render(event: String, fields: [String: String]) -> String {
        let suffix = fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key)=\(encode($0.value))"
        }.joined(separator: " ")
        return suffix.isEmpty ? "\(marker) event=\(encode(event))" :
            "\(marker) event=\(encode(event)) \(suffix)"
    }

    private static func encode(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "\t", with: "%09")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "=", with: "%3D")
    }
}
