#if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
import Foundation
import SWBCore
import SWBUtil

package enum DirectLinkPlanExporter {
    private struct Manifest: Codable {
        static let schema = "swift-build-direct-link-plan-v1"

        let schema: String
        let actionKey: String?
        let commandDigest: String
        let ruleInfo: [String]
        let commandLine: [String]
        let workingDirectory: String
        let inputs: [String]
        let outputs: [String]
        let environment: [String: String]

        init(task: any ExecutableTask, commandLine: [String]) {
            schema = Self.schema
            actionKey = ProcessInfo.processInfo.environment[
                "SWIFT_BUILD_DRIVER_PLAN_CACHE_KEY"
            ]
            commandDigest = Self.digest(
                fields: commandLine
                    + [task.workingDirectory.str]
                    + task.ruleInfo
                    + task.outputPaths.map(\.str)
            )
            ruleInfo = task.ruleInfo
            self.commandLine = commandLine
            workingDirectory = task.workingDirectory.str
            inputs = task.inputPaths.map(\.str)
            outputs = task.outputPaths.map(\.str)
            environment = task.environment.bindingsDictionary
        }

        private static func digest(fields: [String]) -> String {
            let context = SHA256Context()
            for field in fields {
                let bytes = Array(field.utf8)
                context.add(number: UInt64(bytes.count))
                context.add(bytes: bytes)
            }
            return context.signature.asString
        }
    }

    package static func export(
        task: any ExecutableTask,
        commandLine: [String],
        fs: any FSProxy
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            task.ruleInfo.first == "Ld",
            let root = environment["SWIFT_BUILD_DRIVER_PLAN_CACHE_ROOT"],
            environment["SWIFT_BUILD_DRIVER_PLAN_CACHE_MODE"] == "record"
        else {
            return
        }
        let manifest = Manifest(task: task, commandLine: commandLine)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = ByteString(try encoder.encode(manifest))
        let path = Path(root)
            .join("direct-links")
            .join(String(manifest.commandDigest.prefix(2)))
            .join("\(manifest.commandDigest).json")
        try fs.createDirectory(path.dirname, recursive: true)
        if fs.exists(path) {
            guard try fs.read(path) == bytes else {
                throw StubError.error(
                    "Direct link plan conflict for exact command digest."
                )
            }
        } else {
            try fs.write(path, contents: bytes, atomically: true)
        }
    }
}
#endif
