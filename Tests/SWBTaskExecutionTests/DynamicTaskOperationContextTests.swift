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

import Testing

import SWBTaskExecution
import SWBTestSupport
import SWBUtil

private final class SendableDynamicTaskOperationContext: @unchecked Sendable {
    let value: DynamicTaskOperationContext

    init(_ value: DynamicTaskOperationContext) {
        self.value = value
    }
}

@Suite(.requireHostOS(.macOS))
fileprivate struct DynamicTaskOperationContextTests: CoreBasedTests {
    private func makeContext() async throws -> DynamicTaskOperationContext {
        DynamicTaskOperationContext(
            core: try await getCore(),
            definingTargetsByModuleName: [:],
            cas: nil
        )
    }

    @Test
    func acceleratorCacheQuarantineHasExactlyOneConcurrentFirstWriter() async throws {
        let context = try await makeContext()
        let sendableContext = SendableDynamicTaskOperationContext(context)
        #expect(!context.isAcceleratorCacheQuarantined)

        let firstWriterCount = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    sendableContext.value.quarantineAcceleratorCache() ? 1 : 0
                }
            }

            var count = 0
            for await result in group {
                count += result
            }
            return count
        }

        #expect(firstWriterCount == 1)
        #expect(context.isAcceleratorCacheQuarantined)
        #expect(!context.quarantineAcceleratorCache())
    }

    @Test
    func acceleratorCacheQuarantineResetsAfterCompletionWait() async throws {
        let context = try await makeContext()
        #expect(context.quarantineAcceleratorCache())
        #expect(context.isAcceleratorCacheQuarantined)

        let completionToken = await context.waitForCompletion()
        context.reset(completionToken: completionToken)

        #expect(!context.isAcceleratorCacheQuarantined)
        #expect(context.quarantineAcceleratorCache())
    }
}
