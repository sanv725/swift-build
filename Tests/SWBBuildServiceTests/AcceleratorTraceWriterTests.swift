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

import Dispatch
import Foundation
import Testing
import Synchronization

import SWBBuildService
import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBTaskExecution
import SWBUtil

@Suite fileprivate struct AcceleratorTraceWriterTests {
    @Test func configurationRequiresExplicitEnablementAndAbsolutePath() {
        #expect(AcceleratorTraceWriter.Configuration(environment: [:]) == nil)
        #expect(AcceleratorTraceWriter.Configuration(environment: [
            "SWIFT_BUILD_ACCELERATOR_TRACE": "1",
        ]) == nil)
        #expect(AcceleratorTraceWriter.Configuration(environment: [
            "SWIFT_BUILD_ACCELERATOR_TRACE": "1",
            "SWIFT_BUILD_ACCELERATOR_TRACE_PATH": "relative/path",
        ]) == nil)
        #expect(AcceleratorTraceWriter.Configuration(environment: [
            "SWIFT_BUILD_ACCELERATOR_TRACE": "yes",
            "SWIFT_BUILD_ACCELERATOR_TRACE_PATH": "/tmp/traces",
        ]) == nil)

        for enabled in ["1", "YES", "true"] {
            let configuration = AcceleratorTraceWriter.Configuration(environment: [
                "SWIFT_BUILD_ACCELERATOR_TRACE": enabled,
                "SWIFT_BUILD_ACCELERATOR_TRACE_PATH": "/tmp/traces",
            ])
            #expect(configuration?.outputDirectory == Path("/tmp/traces"))
            #expect(configuration?.capacity == AcceleratorTraceWriter.Configuration.defaultCapacity)
            #expect(configuration?.privacyMode == .redacted)
        }
    }

    @Test func configurationClampsCapacityAndRequiresExplicitDebugPrivacy() {
        func configuration(capacity: String, privacy: String? = nil) -> AcceleratorTraceWriter.Configuration? {
            var environment = [
                "SWIFT_BUILD_ACCELERATOR_TRACE": "1",
                "SWIFT_BUILD_ACCELERATOR_TRACE_PATH": "/tmp/traces",
                "SWIFT_BUILD_ACCELERATOR_TRACE_CAPACITY": capacity,
            ]
            environment["SWIFT_BUILD_ACCELERATOR_TRACE_PRIVACY"] = privacy
            return AcceleratorTraceWriter.Configuration(environment: environment)
        }

        #expect(configuration(capacity: "not-a-number")?.capacity == AcceleratorTraceWriter.Configuration.defaultCapacity)
        #expect(configuration(capacity: "1")?.capacity == 256)
        #expect(configuration(capacity: "100000")?.capacity == 65536)
        #expect(configuration(capacity: "1024", privacy: "DEBUG")?.privacyMode == .redacted)
        #expect(configuration(capacity: "1024", privacy: "debug")?.privacyMode == .debug)
    }

    @Test func envelopeIsVersionedAndUsesDeterministicSequenceAndClock() throws {
        let sink = TestAcceleratorTraceSink()
        let clockValue = SWBMutex<UInt64>(1_000)
        let writer = makeWriter(sink: sink) {
            clockValue.withLock { value in
                defer { value += 25 }
                return value
            }
        }

        writer.emitForTesting(event: "probe", payload: ["answer": .integer(42)])
        writer.flushForTesting()

        let events = try sink.events()
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event["schema_major"] as? Int == 1)
        #expect(event["schema_minor"] as? Int == 2)
        #expect(event["event"] as? String == "probe")
        #expect(event["build_id"] as? String == testBuildID.uuidString.lowercased())
        #expect(event["sequence"] as? Int == 1)
        #expect(event["timestamp_ns"] as? Int == 25)
        let payload = try #require(event["payload"] as? [String: Any])
        #expect(payload["answer"] as? Int == 42)
    }

    @Test func concurrentEmissionProducesStrictFileSequence() throws {
        let sink = TestAcceleratorTraceSink()
        let writer = makeWriter(sink: sink)

        DispatchQueue.concurrentPerform(iterations: 512) { index in
            writer.emitForTesting(event: "probe", payload: ["index": .integer(index)])
        }
        writer.flushForTesting()

        let sequences = try sink.events().compactMap { $0["sequence"] as? Int }
        #expect(sequences == Array(1...512))
        #expect(Set(sequences).count == 512)
    }

    @Test func batchedEmissionPreservesSequenceAndUsesBoundedWrites() throws {
        let sink = TestAcceleratorTraceSink()
        let writer = makeWriter(sink: sink)

        writer.emitBatchForTesting(count: 532)
        writer.flushForTesting()

        let events = try sink.events()
        #expect(events.count == 532)
        #expect(events.compactMap { $0["sequence"] as? Int } == Array(1...532))
        #expect(events.compactMap { ($0["payload"] as? [String: Any])?["index"] as? Int } == Array(0..<532))
        #expect(sink.writeCount == 3)
        #expect(writer.snapshotForTesting.droppedEventCount == 0)
    }

    @Test func minimumCapacityBatchedEmissionDoesNotDrop() throws {
        let sink = TestAcceleratorTraceSink()
        let writer = makeWriter(sink: sink, capacity: 256)

        writer.emitBatchForTesting(count: 256)
        writer.flushForTesting()

        let events = try sink.events()
        #expect(events.count == 256)
        #expect(events.compactMap { $0["sequence"] as? Int } == Array(1...256))
        #expect(events.compactMap { ($0["payload"] as? [String: Any])?["index"] as? Int } == Array(0..<256))
        #expect(sink.writeCount == 1)
        #expect(writer.snapshotForTesting.droppedEventCount == 0)
    }

    @Test func overflowDropsNewestButRetainsTerminalSummary() throws {
        let sink = TestAcceleratorTraceSink(blockFirstWrite: true)
        let writer = makeWriter(sink: sink, capacity: 256)

        writer.emitForTesting(event: "seed")
        #expect(sink.waitUntilFirstWriteBegins())

        for index in 0..<300 {
            writer.emitForTesting(event: "probe", payload: ["index": .integer(index)])
        }
        let overflowSnapshot = writer.snapshotForTesting
        #expect(overflowSnapshot.droppedEventCount == 44)
        #expect(overflowSnapshot.pendingEventCount == 256)

        writer.buildFinished(status: .succeeded, metrics: nil)
        sink.releaseFirstWrite()
        writer.flushForTesting()

        let events = try sink.events()
        let finalEvent = try #require(events.last)
        #expect(finalEvent["event"] as? String == "build_finished")
        let payload = try #require(finalEvent["payload"] as? [String: Any])
        #expect(payload["status"] as? String == "succeeded")
        #expect(payload["dropped_event_count"] as? Int == 44)
        #expect(sink.closeCount == 1)
    }

    @Test func sinkFailureDisablesWriterWithoutEscaping() throws {
        let sink = TestAcceleratorTraceSink(failOnWrite: true)
        let writer = makeWriter(sink: sink)

        writer.emitForTesting(event: "first")
        writer.flushForTesting()

        let failedSnapshot = writer.snapshotForTesting
        #expect(failedSnapshot.disabled)
        #expect(failedSnapshot.writerErrorCount == 1)
        #expect(failedSnapshot.pendingEventCount == 0)
        #expect(sink.closeCount == 1)

        writer.emitForTesting(event: "ignored")
        writer.buildFinished(status: .failed, metrics: nil)
        writer.flushForTesting()

        #expect(try sink.events().isEmpty)
        #expect(writer.snapshotForTesting == failedSnapshot)
    }

    @Test func redactedModeOmitsRawTaskIdentityAndDebugModeScopesIt() throws {
        let secret = "/Users/example/private-project/Secret.swift"
        let taskIdentifier = TaskIdentifier(rawValue: secret)
        let task = OutputParserMockTask(basenames: [], exec: secret)

        let redactedSink = TestAcceleratorTraceSink()
        let redactedWriter = makeWriter(sink: redactedSink, privacyMode: .redacted)
        redactedWriter.taskStarted(taskIdentifier: taskIdentifier, task: task)
        redactedWriter.flushForTesting()

        #expect(!redactedSink.string.contains(secret))
        let redactedDeclaration = try #require(try redactedSink.events().first { $0["event"] as? String == "task_declared" })
        let redactedPayload = try #require(redactedDeclaration["payload"] as? [String: Any])
        #expect(redactedPayload["debug"] == nil)
        #expect(redactedPayload["task_id"] as? String == "t1")

        let debugSink = TestAcceleratorTraceSink()
        let debugWriter = makeWriter(sink: debugSink, privacyMode: .debug)
        debugWriter.taskStarted(taskIdentifier: taskIdentifier, task: task)
        debugWriter.flushForTesting()

        let debugDeclaration = try #require(try debugSink.events().first { $0["event"] as? String == "task_declared" })
        let debugPayload = try #require(debugDeclaration["payload"] as? [String: Any])
        let debug = try #require(debugPayload["debug"] as? [String: Any])
        #expect(debug["task_identifier"] as? String == secret)
        #expect(debugPayload.keys.filter { $0 != "debug" }.allSatisfy { key in
            !String(describing: debugPayload[key]).contains(secret)
        })
    }

    @Test func cacheObservationRedactsRawKeysAndPreservesBoundedFields() throws {
        let rawKey = "llvmcas://private-key-/Users/example/Secret.swift"
        let secondRawKey = "cas-id-private-module-target-environment"
        let distinctRawKey = "distinct-private-cache-key"
        let taskIdentifier = TaskIdentifier(rawValue: "/Users/example/private-project/Secret.swift")
        let task = OutputParserMockTask(basenames: [], exec: "swift-frontend")
        let sink = TestAcceleratorTraceSink()
        let writer = makeWriter(sink: sink, privacyMode: .redacted)
        let observation = TaskCacheObservation(
            cacheKeys: [rawKey, secondRawKey],
            mode: .verify,
            eligibility: .eligible,
            outcome: .verifyMatch,
            lookupDurationNS: 11,
            materializationDurationNS: 12,
            verificationDurationNS: 13,
            scrubDurationNS: 14,
            compilerDurationNS: 15,
            scrubOutcome: .succeeded,
            outputCount: 2,
            outputBytes: 100,
            mismatchCount: 0,
            comparedBytes: 100,
            finalDisposition: .verifiedThenExecuted
        )

        writer.cacheObservations(taskIdentifier: taskIdentifier, task: task, observations: [observation])
        writer.cacheObservations(
            taskIdentifier: taskIdentifier,
            task: task,
            observations: [TaskCacheObservation(
                cacheKeys: [secondRawKey, rawKey],
                mode: .observe,
                eligibility: .ineligible,
                exclusionReason: .unsupportedOutput,
                outcome: .excluded,
                finalDisposition: .executed
            )]
        )
        writer.cacheObservations(
            taskIdentifier: taskIdentifier,
            task: task,
            observations: [TaskCacheObservation(
                cacheKeys: [distinctRawKey],
                mode: .observe,
                eligibility: .eligible,
                outcome: .miss,
                finalDisposition: .executed
            )]
        )
        writer.flushForTesting()

        #expect(!sink.string.contains(rawKey))
        #expect(!sink.string.contains(secondRawKey))
        #expect(!sink.string.contains(distinctRawKey))
        #expect(!sink.string.contains("Secret.swift"))
        let observations = try sink.events().filter { $0["event"] as? String == "cache_observation" }
        #expect(observations.count == 3)
        let firstPayload = try #require(observations.first?["payload"] as? [String: Any])
        let secondPayload = try #require(observations.dropFirst().first?["payload"] as? [String: Any])
        let thirdPayload = try #require(observations.last?["payload"] as? [String: Any])
        #expect(observations.allSatisfy { $0["schema_major"] as? Int == 1 })
        #expect(observations.allSatisfy { $0["schema_minor"] as? Int == 2 })
        let firstIdentity = try #require(firstPayload["key_identity"] as? String)
        let firstLookupID = try #require(firstPayload["lookup_id"] as? String)
        #expect(firstIdentity.hasPrefix("hmac-sha256:"))
        #expect(firstIdentity == secondPayload["key_identity"] as? String)
        #expect(firstLookupID == "l1")
        #expect(secondPayload["lookup_id"] as? String == "l2")
        #expect(thirdPayload["lookup_id"] as? String == "l3")
        #expect(firstPayload["source"] as? String == "swift")
        #expect(firstPayload["exclusion_reason"] is NSNull)
        #expect(secondPayload["exclusion_reason"] as? String == "unsupported_output")
        #expect(firstPayload["key_count"] as? Int == 2)
        #expect(firstPayload["mode"] as? String == "verify")
        #expect(firstPayload["outcome"] as? String == "verify_match")
        #expect(firstPayload["final_disposition"] as? String == "verified_then_executed")
        let timings = try #require(firstPayload["timings"] as? [String: Any])
        #expect(timings["lookup_duration_ns"] as? Int == 11)
        let outputs = try #require(firstPayload["outputs"] as? [String: Any])
        #expect(outputs["count"] as? Int == 2)
        #expect(outputs["mismatch_count"] as? Int == 0)
    }

    @Test func cacheObservationEmitsBoundedTrustControlFallbackReasons() throws {
        let taskIdentifier = TaskIdentifier(rawValue: "trust-control-task")
        let task = OutputParserMockTask(basenames: [], exec: "swift-frontend")
        let sink = TestAcceleratorTraceSink()
        let writer = makeWriter(sink: sink, privacyMode: .redacted)

        writer.cacheObservations(
            taskIdentifier: taskIdentifier,
            task: task,
            observations: [
                TaskCacheObservation(
                    mode: .trust,
                    eligibility: .eligible,
                    outcome: .unavailable,
                    fallbackReason: .unauthorizedTrust,
                    finalDisposition: .executed
                ),
                TaskCacheObservation(
                    mode: .verify,
                    eligibility: .eligible,
                    outcome: .unavailable,
                    fallbackReason: .buildQuarantined,
                    finalDisposition: .executed
                ),
            ]
        )
        writer.flushForTesting()

        let observations = try sink.events().filter { $0["event"] as? String == "cache_observation" }
        #expect(observations.count == 2)
        #expect(observations.allSatisfy { $0["schema_major"] as? Int == 1 })
        #expect(observations.allSatisfy { $0["schema_minor"] as? Int == 2 })
        let payloads = try observations.map { event in
            try #require(event["payload"] as? [String: Any])
        }
        #expect(payloads.map { $0["outcome"] as? String } == ["unavailable", "unavailable"])
        #expect(payloads.map { $0["fallback_reason"] as? String } == ["unauthorized_trust", "build_quarantined"])
        #expect(payloads.allSatisfy { $0["exclusion_reason"] is NSNull })
        #expect(payloads.allSatisfy { $0["final_disposition"] as? String == "executed" })
    }

    @Test func finishIsTerminalAndClosesAfterDraining() throws {
        let sink = TestAcceleratorTraceSink()
        let writer = makeWriter(sink: sink)

        writer.emitForTesting(event: "before_finish")
        writer.buildFinished(status: .cancelled, metrics: nil)
        #expect(sink.closeCount == 1, "cancelled builds must synchronously persist terminal evidence")
        writer.emitForTesting(event: "after_finish")
        writer.flushForTesting()

        let events = try sink.events()
        #expect(events.compactMap { $0["event"] as? String } == ["before_finish", "build_finished"])
        let finalPayload = try #require(events.last?["payload"] as? [String: Any])
        #expect(finalPayload["status"] as? String == "cancelled")
        #expect(finalPayload["writer_error_count"] as? Int == 0)
        #expect(finalPayload["dropped_event_count"] as? Int == 0)
        #expect(sink.closeCount == 1)
    }
}

private let testBuildID = UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!

private func makeWriter(
    sink: TestAcceleratorTraceSink,
    capacity: Int = AcceleratorTraceWriter.Configuration.defaultCapacity,
    privacyMode: AcceleratorTraceWriter.PrivacyMode = .redacted,
    clock: @escaping @Sendable () -> UInt64 = { 10_000 }
) -> AcceleratorTraceWriter {
    AcceleratorTraceWriter(
        buildID: testBuildID,
        activeBuildID: 7,
        parameters: BuildParameters(configuration: "Debug", activeArchitecture: "arm64"),
        configuration: .init(outputDirectory: Path("/unused"), capacity: capacity, privacyMode: privacyMode),
        sink: sink,
        clock: clock
    )
}

private enum TestSinkError: Error {
    case failedWrite
}

private final class TestAcceleratorTraceSink: AcceleratorTraceSink, @unchecked Sendable {
    private struct State {
        var data = Data()
        var closeCount = 0
        var writeCount = 0
    }

    private let state = SWBMutex(State())
    private let failOnWrite: Bool
    private let blockFirstWrite: Bool
    private let firstWriteBegan = DispatchSemaphore(value: 0)
    private let releaseFirstWriteSemaphore = DispatchSemaphore(value: 0)

    init(failOnWrite: Bool = false, blockFirstWrite: Bool = false) {
        self.failOnWrite = failOnWrite
        self.blockFirstWrite = blockFirstWrite
    }

    func write(_ data: Data) throws {
        let writeNumber = state.withLock { state in
            state.writeCount += 1
            return state.writeCount
        }
        if blockFirstWrite && writeNumber == 1 {
            firstWriteBegan.signal()
            releaseFirstWriteSemaphore.wait()
        }
        if failOnWrite {
            throw TestSinkError.failedWrite
        }
        state.withLock { $0.data.append(data) }
    }

    func close() throws {
        state.withLock { $0.closeCount += 1 }
    }

    func waitUntilFirstWriteBegins() -> Bool {
        firstWriteBegan.wait(timeout: .now() + .seconds(5)) == .success
    }

    func releaseFirstWrite() {
        releaseFirstWriteSemaphore.signal()
    }

    var string: String {
        state.withLock { String(decoding: $0.data, as: UTF8.self) }
    }

    var closeCount: Int {
        state.withLock { $0.closeCount }
    }

    var writeCount: Int {
        state.withLock { $0.writeCount }
    }

    func events() throws -> [[String: Any]] {
        let data = state.withLock { $0.data }
        return try data.split(separator: 0x0A).map { line in
            let value = try JSONSerialization.jsonObject(with: Data(line))
            return try #require(value as? [String: Any])
        }
    }
}
