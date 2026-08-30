//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Exception
//
//===----------------------------------------------------------------------===//

import Testing

import SWBTaskExecution

@Suite
fileprivate struct SwiftBuildOptPhaseTimelineTests {
    @Test
    func activationRequiresExactOptIn() {
        #expect(SwiftBuildOptPhaseTimeline.isEnabled(environment: [:]) == false)
        #expect(SwiftBuildOptPhaseTimeline.isEnabled(environment: [
            SwiftBuildOptPhaseTimeline.environmentVariable: "true"
        ]) == false)
        #expect(SwiftBuildOptPhaseTimeline.isEnabled(environment: [
            SwiftBuildOptPhaseTimeline.environmentVariable: "1"
        ]))
    }

    @Test
    func markerIsStableSortedAndSingleLine() {
        #expect(SwiftBuildOptPhaseTimeline.render(
            event: "frontend job",
            fields: ["z": "two\nlines", "a": "x=y"]
        ) == "SWIFT_BUILD_OPT_TIMELINE event=frontend%20job a=x%3Dy z=two%0Alines")
    }

    @Test
    func monotonicClockAdvances() {
        let first = SwiftBuildOptPhaseTimeline.now()
        let second = SwiftBuildOptPhaseTimeline.now()
        #expect(second >= first)
    }
}
