import ArgumentParser
import Foundation
import GLMOCRAdapter
import VLMRuntimeKit

actor DownloadProgressPrinter {
    private let modelID: String
    private var lastCompleted: Int64 = -1

    init(modelID: String) {
        self.modelID = modelID
    }

    func update(completed: Int64, total: Int64) {
        guard completed != lastCompleted else { return }
        lastCompleted = completed

        let total = max(total, 1)
        FileHandle.standardError.write(Data("Downloading \(modelID) (\(completed)/\(total) files)\n".utf8))
    }
}

enum TaskPreset: String, ExpressibleByArgument {
    case text
    case formula
    case table
    case json
}

@main
struct GLMOCRCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "GLMOCRCLI",
        abstract: "GLM-OCR native Swift starter (MLX Swift + HF tooling)."
    )

    @Option(help: "Hugging Face model id to download/use.")
    var model: String = GLMOCRDefaults.modelID

    @Option(help: "Hugging Face revision (branch/tag/commit).")
    var revision: String = GLMOCRDefaults.revision

    @Option(help: "Hub download base directory (defaults to Hugging Face hub cache).")
    var downloadBase: String?

    @Option(help: "Input image or PDF file path.")
    var input: String?

    @Option(help: "Task preset: text | formula | table | json")
    var task: TaskPreset = .text

    @Option(help: "Max new tokens.")
    var maxNewTokens: Int = 2048

    @Flag(help: "Do not run inference; just resolve/download the model snapshot.")
    var downloadOnly: Bool = false

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedFileURL(fromPath path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    mutating func validate() throws {
        guard maxNewTokens > 0 else {
            throw ValidationError("--max-new-tokens must be > 0")
        }

        if downloadOnly { return }
        guard let inputPath = Self.normalizedNonEmpty(input) else {
            throw ValidationError("--input is required unless --download-only is set")
        }

        let url = Self.normalizedFileURL(fromPath: inputPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ValidationError("Input not found: \(url.path)")
        }
        if isDirectory.boolValue {
            throw ValidationError("Input is a directory: \(url.path)")
        }
    }

    mutating func run() async throws {
        let modelID = model
        let downloadBaseURL: URL? = Self.normalizedNonEmpty(downloadBase).map(Self.normalizedFileURL(fromPath:))
        let pipeline = GLMOCRPipeline(modelID: modelID, revision: revision, downloadBase: downloadBaseURL)

        let printer = DownloadProgressPrinter(modelID: modelID)
        try await pipeline.ensureLoaded { progress in
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { await printer.update(completed: completed, total: total) }
        }
        if downloadOnly { return }

        guard let inputPath = Self.normalizedNonEmpty(input) else {
            throw ValidationError("--input is required unless --download-only is set")
        }
        let url = Self.normalizedFileURL(fromPath: inputPath)
        let taskPreset: OCRTask = switch task {
        case .text: .text
        case .formula: .formula
        case .table: .table
        case .json: .structuredJSON(schema: "{\n  \"type\": \"object\"\n}")
        }

        let options = GenerateOptions(maxNewTokens: maxNewTokens, temperature: 0, topP: 1)
        let result = try await pipeline.recognize(.fileURL(url), task: taskPreset, options: options)
        print(result.text)
    }
}
