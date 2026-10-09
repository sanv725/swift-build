//===----------------------------------------------------------------------===//
// Part of the Swift open source project. Licensed under Apache License v2.0
// with Runtime Library Exception. See https://swift.org/LICENSE.txt.
//===----------------------------------------------------------------------===//

#if SWIFT_BUILD_ACCELERATOR_DRIVER_PLAN_CACHE_EXPERIMENT
public import SWBUtil

/// The per-file compile jobs an incremental driver skipped when a plan was recorded
/// (SwiftBuildOptimizer C977). A warm record plans only the files it recompiles, so a later
/// body edit to any other file had no owning job and replay refused it. Replay now promotes
/// the skipped job that owns such a file to an uncached compile, as an incremental build would.
///
/// Skipped jobs differ only in their primary file and its outputs, while each one lists every
/// module source as an input (about 55 KB per job on Reframe's 1,250-file target). They are
/// stored as one template command line and input list, plus each job's differing arguments,
/// and rebuild byte-identically. Jobs whose shapes differ are stored in full.
public struct SwiftDriverSkippedCompileJobs: Serializable, Sendable {
    struct Entry: Serializable, Sendable {
        let displayInputs: [Path]
        let descriptionForLifecycle: String
        let outputs: [Path]
        /// Empty when the job's inputs equal the template's.
        let inputs: [Path]
        let sharesTemplateInputs: Bool
        /// With `argumentIndices` empty and `isDiff` false, the full command line.
        let isDiff: Bool
        let argumentIndices: [Int]
        let arguments: [ByteString]

        func serialize<T>(to serializer: T) where T: Serializer {
            serializer.serializeAggregate(8) {
                serializer.serialize(displayInputs)
                serializer.serialize(descriptionForLifecycle)
                serializer.serialize(outputs)
                serializer.serialize(inputs)
                serializer.serialize(sharesTemplateInputs)
                serializer.serialize(isDiff)
                serializer.serialize(argumentIndices)
                serializer.serialize(arguments)
            }
        }

        init(displayInputs: [Path], descriptionForLifecycle: String, outputs: [Path], inputs: [Path],
             sharesTemplateInputs: Bool, isDiff: Bool, argumentIndices: [Int], arguments: [ByteString]) {
            self.displayInputs = displayInputs
            self.descriptionForLifecycle = descriptionForLifecycle
            self.outputs = outputs
            self.inputs = inputs
            self.sharesTemplateInputs = sharesTemplateInputs
            self.isDiff = isDiff
            self.argumentIndices = argumentIndices
            self.arguments = arguments
        }

        init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(8)
            displayInputs = try deserializer.deserialize()
            descriptionForLifecycle = try deserializer.deserialize()
            outputs = try deserializer.deserialize()
            inputs = try deserializer.deserialize()
            sharesTemplateInputs = try deserializer.deserialize()
            isDiff = try deserializer.deserialize()
            argumentIndices = try deserializer.deserialize()
            arguments = try deserializer.deserialize()
        }
    }

    public static let empty = Self(moduleName: "", inputs: [], commandLine: [], entries: [])

    let moduleName: String
    let inputs: [Path]
    let commandLine: [ByteString]
    let entries: [Entry]

    public var count: Int { entries.count }

    private init(moduleName: String, inputs: [Path], commandLine: [ByteString], entries: [Entry]) {
        self.moduleName = moduleName
        self.inputs = inputs
        self.commandLine = commandLine
        self.entries = entries
    }

    /// Nil unless every job is a target `Compile` job of one module.
    init?(jobs: [SwiftDriverJob]) {
        guard let first = jobs.first else { self = .empty; return }
        guard jobs.allSatisfy({
            if case .target = $0.kind { return $0.ruleInfoType == "Compile" && $0.moduleName == first.moduleName }
            return false
        }) else { return nil }
        self.moduleName = first.moduleName
        self.inputs = first.inputs
        self.commandLine = first.commandLine
        self.entries = jobs.map { job in
            let sharesInputs = job.inputs == first.inputs
            var indices: [Int] = []
            var arguments: [ByteString] = []
            let isDiff = job.commandLine.count == first.commandLine.count
            if isDiff {
                for (index, argument) in job.commandLine.enumerated() where argument != first.commandLine[index] {
                    indices.append(index)
                    arguments.append(argument)
                }
            } else {
                arguments = job.commandLine
            }
            return Entry(displayInputs: job.displayInputs, descriptionForLifecycle: job.descriptionForLifecycle,
                         outputs: job.outputs, inputs: sharesInputs ? [] : job.inputs,
                         sharesTemplateInputs: sharesInputs, isDiff: isDiff,
                         argumentIndices: indices, arguments: arguments)
        }
    }

    func inputs(of index: Int) -> [Path] {
        entries[index].sharesTemplateInputs ? inputs : entries[index].inputs
    }

    /// Every distinct input list, for absence proofs.
    var distinctInputLists: [[Path]] {
        guard !entries.isEmpty else { return [] }
        return [inputs] + entries.filter { !$0.sharesTemplateInputs }.map(\.inputs)
    }

    /// The `-primary-file` operands of job `index`, without rebuilding its command line.
    func primaryFiles(of index: Int) -> [String] {
        let entry = entries[index]
        guard entry.isDiff else {
            let arguments = entry.arguments
            return arguments.indices.filter { arguments[$0] == "-primary-file" && $0 + 1 < arguments.count }
                .map { arguments[$0 + 1].asString }
        }
        func argument(_ position: Int) -> ByteString {
            var low = 0, high = entry.argumentIndices.count
            while low < high {
                let middle = (low + high) / 2
                if entry.argumentIndices[middle] < position { low = middle + 1 } else { high = middle }
            }
            return low < entry.argumentIndices.count && entry.argumentIndices[low] == position
                ? entry.arguments[low] : commandLine[position]
        }
        return commandLine.indices.filter { $0 + 1 < commandLine.count && argument($0) == "-primary-file" }
            .map { argument($0 + 1).asString }
    }

    func job(at index: Int) -> SwiftDriverJob {
        let entry = entries[index]
        var arguments = commandLine
        if entry.isDiff {
            for (position, argument) in zip(entry.argumentIndices, entry.arguments) { arguments[position] = argument }
        } else {
            arguments = entry.arguments
        }
        return SwiftDriverJob(skippedCompileModule: moduleName, inputs: inputs(of: index),
                              displayInputs: entry.displayInputs,
                              descriptionForLifecycle: entry.descriptionForLifecycle,
                              outputs: entry.outputs, commandLine: arguments)
    }

    public func serialize<T>(to serializer: T) where T: Serializer {
        serializer.serializeAggregate(4) {
            serializer.serialize(moduleName)
            serializer.serialize(inputs)
            serializer.serialize(commandLine)
            serializer.serialize(entries)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        moduleName = try deserializer.deserialize()
        inputs = try deserializer.deserialize()
        commandLine = try deserializer.deserialize()
        entries = try deserializer.deserialize()
        for entry in entries {
            guard entry.argumentIndices.count == (entry.isDiff ? entry.arguments.count : 0),
                  entry.argumentIndices == entry.argumentIndices.sorted(),
                  entry.argumentIndices.allSatisfy({ (0..<commandLine.count).contains($0) }) else {
                throw StubError.error("Recorded skipped compile job is malformed.")
            }
        }
    }
}
#endif
