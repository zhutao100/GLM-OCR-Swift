import ArgumentParser
import Foundation
import GLMOCRAdapter
import VLMRuntimeKit

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
    var input: String

    @Option(help: "Task preset: text | formula | table | json")
    var task: String = "text"

    @Option(help: "Max new tokens.")
    var maxNewTokens: Int = 2048

    @Flag(help: "Do not run inference; just resolve/download the model snapshot.")
    var downloadOnly: Bool = false

    mutating func run() async throws {
        func normalize(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }

        let downloadBaseURL: URL? = normalize(downloadBase).map { URL(fileURLWithPath: $0).standardizedFileURL }
        let pipeline = GLMOCRPipeline(modelID: model, revision: revision, downloadBase: downloadBaseURL)

        var lastCompleted: Int64 = -1
        try await pipeline.ensureLoaded { progress in
            if progress.completedUnitCount != lastCompleted {
                lastCompleted = progress.completedUnitCount
                let total = max(progress.totalUnitCount, 1)
                FileHandle.standardError.write(Data("Downloading \(model) (\(lastCompleted)/\(total) files)\n".utf8))
            }
        }
        if downloadOnly { return }

        let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
        let taskPreset: OCRTask = switch task.lowercased() {
        case "text": .text
        case "formula": .formula
        case "table": .table
        case "json": .structuredJSON(schema: "{\n  \"type\": \"object\"\n}")
        default: .text
        }

        let options = GenerateOptions(maxNewTokens: maxNewTokens, temperature: 0, topP: 1)
        let result = try await pipeline.recognize(.fileURL(url), task: taskPreset, options: options)
        print(result.text)
    }
}
