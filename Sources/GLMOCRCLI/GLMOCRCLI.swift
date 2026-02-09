import ArgumentParser
import Foundation
import GLMOCRAdapter
import MLX
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

    @Flag(help: "Developer: load the model and run a single forward pass (synthetic inputs).")
    var devForwardPass: Bool = false

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

        if downloadOnly || devForwardPass { return }
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

        let printer = DownloadProgressPrinter(modelID: modelID)
        let store: any ModelStore = HuggingFaceHubModelStore()
        let request = ModelSnapshotRequest(modelID: modelID, revision: revision, matchingGlobs: GLMOCRDefaults.downloadGlobs)
        let folder = try await store.resolveSnapshot(request, downloadBase: downloadBaseURL) { progress in
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { await printer.update(completed: completed, total: total) }
        }
        if downloadOnly { return }

        if devForwardPass {
            try await runDevForwardPass(modelFolder: folder)
            return
        }

        let pipeline = GLMOCRPipeline(modelID: modelID, revision: revision, downloadBase: downloadBaseURL)
        try await pipeline.ensureLoaded(progress: nil)

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

    private func runDevForwardPass(modelFolder: URL) async throws {
        let config = try GLMOCRConfig.load(from: modelFolder)
        let tokenizer = try await GLMOCRTokenizer.load(from: modelFolder, config: config)
        let ids = tokenizer.specialTokenIDs

        let imageSize = config.visionConfig.imageSize ?? 336
        let patchSize = config.visionConfig.patchSize ?? 14
        let temporalPatchSize = config.visionConfig.temporalPatchSize ?? 2
        let mergeSize = config.visionConfig.spatialMergeSize ?? 2

        let grid = imageSize / patchSize
        let downGrid = grid / mergeSize
        let numImageTokens = downGrid * downGrid // depth collapses to 1 when D == temporalPatchSize

        MLXRandom.seed(0)
        let pixelValues = MLXRandom.normal([1, temporalPatchSize, imageSize, imageSize, 3]).asType(.bfloat16)

        let promptTokenIDs = tokenizer.tokenizer.encode(text: " OCR:", addSpecialTokens: false)
        var inputIds: [Int] = [ids.gMaskId, ids.sopId, ids.userId, ids.beginImageId]
        inputIds.append(contentsOf: Array(repeating: ids.imageId, count: numImageTokens))
        inputIds.append(ids.endImageId)
        inputIds.append(contentsOf: promptTokenIDs)

        let inputIdArray = MLXArray(inputIds.map { Int32($0) }).reshaped(1, -1)

        let model = try await GLMOCRModel.load(from: modelFolder)
        let logits = try model.forward(inputIds: inputIdArray, pixelValues: pixelValues)
        try checkedEval(logits)

        let shape = logits.shape
        FileHandle.standardError.write(Data("Logits shape: \(shape)\n".utf8))

        let last = logits[0, -1].asType(.float32).asArray(Float.self)
        let topK = 5
        let pairs = last.enumerated().sorted(by: { $0.element > $1.element }).prefix(topK)
        for (id, value) in pairs {
            FileHandle.standardError.write(Data("top\(topK): id=\(id) logit=\(value)\n".utf8))
        }
    }
}
