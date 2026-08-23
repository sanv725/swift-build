//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Synchronization
package import SWBCore
package import SWBCAS
package import SWBUtil

#if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT && SWIFT_BUILD_ACCELERATOR_UNSAFE_PARALLEL_REPLAY_EXPERIMENT
/// A process-resident, bounded worker pool for the unsafe replay experiment.
///
/// The stock experiment used `concurrentPerform` once per compile batch. This
/// executor pays thread creation and readiness costs once, then accepts the
/// small synchronous replay batches produced throughout a build.
package final class UnsafePersistentSwiftCacheReplayExecutor: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var jobs: [@Sendable () -> Void] = []
        var nextJobIndex = 0
        var isStopping = false
    }

    private final class BatchCompletion: @unchecked Sendable {
        let condition = NSCondition()
        var remaining: Int

        init(remaining: Int) {
            self.remaining = remaining
        }

        func complete() {
            condition.lock()
            remaining -= 1
            if remaining == 0 {
                condition.broadcast()
            }
            condition.unlock()
        }

        func wait() {
            condition.lock()
            while remaining > 0 {
                condition.wait()
            }
            condition.unlock()
        }
    }

    package let maximumParallelism: Int
    private let state = State()
    private var workers: [Thread] = []

    package init(maximumParallelism: Int) {
        precondition(maximumParallelism > 1)
        self.maximumParallelism = maximumParallelism
        workers = (0..<maximumParallelism).map { workerIndex in
            let worker = Thread { [state] in
                while true {
                    let job: (@Sendable () -> Void)?
                    state.condition.lock()
                    while state.nextJobIndex == state.jobs.count && !state.isStopping {
                        state.condition.wait()
                    }
                    if state.nextJobIndex < state.jobs.count {
                        job = state.jobs[state.nextJobIndex]
                        state.nextJobIndex += 1
                        if state.nextJobIndex == state.jobs.count {
                            state.jobs.removeAll(keepingCapacity: true)
                            state.nextJobIndex = 0
                        }
                    } else {
                        job = nil
                    }
                    let shouldStop = state.isStopping && job == nil
                    state.condition.unlock()

                    if shouldStop {
                        return
                    }
                    job?()
                }
            }
            worker.name = "org.swift.swift-build.accelerator-replay-\(workerIndex)"
            return worker
        }
        for worker in workers {
            worker.start()
        }
    }

    deinit {
        state.condition.lock()
        state.isStopping = true
        state.condition.broadcast()
        state.condition.unlock()
    }

    /// Runs exactly `min(iterations, maximumParallelism)` persistent workers
    /// and does not return until all worker closures have drained.
    package func perform(iterations: Int, _ body: @escaping @Sendable (Int) -> Void) {
        let activeWorkerCount = min(iterations, maximumParallelism)
        guard activeWorkerCount > 0 else { return }

        let completion = BatchCompletion(remaining: activeWorkerCount)
        state.condition.lock()
        for workerIndex in 0..<activeWorkerCount {
            state.jobs.append {
                body(workerIndex)
                completion.complete()
            }
        }
        state.condition.broadcast()
        state.condition.unlock()
        completion.wait()
    }
}
#endif

public final class DynamicTaskOperationContext {
    private let core: Core
    package private(set) var clangModuleDependencyGraph: ClangModuleDependencyGraph
    package private(set) var swiftModuleDependencyGraph: SwiftModuleDependencyGraph
    package private(set) var compilationCachingUploader: CompilationCachingUploader
    package private(set) var compilationCachingDataPruner: CompilationCachingDataPruner
    package let definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>]
    package let cas: ToolchainCAS?
    private let acceleratorCacheQuarantined = SWBMutex(false)
    #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT && SWIFT_BUILD_ACCELERATOR_UNSAFE_PARALLEL_REPLAY_EXPERIMENT
    private let unsafeReplayExecutors = SWBMutex([Int: UnsafePersistentSwiftCacheReplayExecutor]())
    #endif

    package var isAcceleratorCacheQuarantined: Bool {
        acceleratorCacheQuarantined.withLock { $0 }
    }

    package init(core: Core, definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>], cas: ToolchainCAS?) {
        self.core = core
        self.clangModuleDependencyGraph = ClangModuleDependencyGraph(core: core, definingTargetsByModuleName: definingTargetsByModuleName)
        self.swiftModuleDependencyGraph = SwiftModuleDependencyGraph()
        self.compilationCachingUploader = CompilationCachingUploader()
        self.compilationCachingDataPruner = CompilationCachingDataPruner()
        self.definingTargetsByModuleName = definingTargetsByModuleName
        self.cas = cas
    }

    /// Quarantines accelerator-cache replay for the remainder of this build.
    ///
    /// Returns `true` only for the caller that transitions the latch from
    /// unquarantined to quarantined.
    @discardableResult
    package func quarantineAcceleratorCache() -> Bool {
        acceleratorCacheQuarantined.withLock { quarantined in
            guard !quarantined else { return false }
            quarantined = true
            return true
        }
    }

    #if SWIFT_BUILD_ACCELERATOR_UNSAFE_TRUST_EXPERIMENT && SWIFT_BUILD_ACCELERATOR_UNSAFE_PARALLEL_REPLAY_EXPERIMENT
    package func unsafeReplayExecutor(maximumParallelism: Int) -> UnsafePersistentSwiftCacheReplayExecutor {
        unsafeReplayExecutors.withLock { executors in
            if let executor = executors[maximumParallelism] {
                return executor
            }
            let executor = UnsafePersistentSwiftCacheReplayExecutor(maximumParallelism: maximumParallelism)
            executors[maximumParallelism] = executor
            return executor
        }
    }
    #endif

    @discardableResult package func waitForCompletion() async -> DynamicTaskOperationContextCompletionToken {
        await self.clangModuleDependencyGraph.waitForCompletion()
        await self.swiftModuleDependencyGraph.waitForCompletion()
        await self.compilationCachingUploader.waitForCompletion()
        await self.compilationCachingDataPruner.waitForCompletion()
        return DynamicTaskOperationContextCompletionToken()
    }

    package func reset(completionToken: consuming DynamicTaskOperationContextCompletionToken) {
        completionToken.run {
            self.clangModuleDependencyGraph = ClangModuleDependencyGraph(core: core, definingTargetsByModuleName: clangModuleDependencyGraph.definingTargetsByModuleName)
            self.swiftModuleDependencyGraph = SwiftModuleDependencyGraph()
            self.compilationCachingUploader = CompilationCachingUploader()
            self.compilationCachingDataPruner = CompilationCachingDataPruner()
            self.acceleratorCacheQuarantined.withLock { $0 = false }
        }
    }

    func readSerializedDiagnostics(at path: Path, workingDirectory: Path, appendToOutputStream: Bool, attachmentInfo: LibclangDiagnosticAttachmentInfo?, fs: any FSProxy) -> [Diagnostic] {
        do {
            // Some compilers write an empty file when there are no diagnostics, which is rejected by libclang.
            guard try fs.exists(path) && fs.getFileSize(path).count > 0 else {
                return []
            }
            guard let toolchain = core.toolchainRegistry.defaultToolchain else {
                throw StubError.error("unable to find libclang (no default toolchain)")
            }
            let libclangPath = try toolchain.lookup(subject: .library(basename: "clang"), operatingSystem: core.hostOperatingSystem)
            guard let libClang = core.lookupLibclang(path: libclangPath).libclang else {
                throw StubError.error("unable to open libclang: '\(libclangPath.str)'")
            }
            let serializedDiagnostics = try libClang.loadDiagnostics(filePath: path.str).map {
                Diagnostic($0, workingDirectory: workingDirectory, appendToOutputStream: appendToOutputStream, attachmentInfo: attachmentInfo)
            }
            return serializedDiagnostics
        } catch {
            return []
        }
    }
}

/// Opaque "token" used to enforce that ``DynamicTaskOperationContext/waitForCompletion()`` is always called immediately prior to invoking ``DynamicTaskOperationContext/reset(completionToken:)``.
package struct DynamicTaskOperationContextCompletionToken: Sendable {
    fileprivate init() { }
    consuming fileprivate func run(body: () -> Void) {
        body()
    }
}
