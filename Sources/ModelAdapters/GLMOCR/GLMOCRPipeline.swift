import CoreImage
import Foundation
import VLMRuntimeKit

public enum GLMOCRPipelineError: Error, Sendable {
    case modelNotLoaded
    case invalidInputURL(URL)
    case inputNotFound(URL)
    case inputIsDirectory(URL)
    case unsupportedInput(URL)
    case invalidPDFPageIndex(Int)
}

/// Input types supported by the pipeline.
public enum GLMOCRInput: Sendable, Equatable {
    /// File URL (image or PDF). `page` is 1-based and only applies to PDFs.
    case file(URL, page: Int)
    case predecodedText(String)

    public static func fileURL(_ url: URL) -> GLMOCRInput { .file(url, page: 1) }
}

/// Main pipeline entrypoint.
/// - Responsible for: model snapshot resolution, prompt building, generation.
/// - Delegates model-agnostic concerns to VLMRuntimeKit.
public actor GLMOCRPipeline: OCRPipeline {
    public typealias Input = GLMOCRInput

    private let store: any ModelStore
    private let processor: GLMOCRProcessor

    private let modelID: String
    private let revision: String
    private let downloadGlobs: [String]
    private let downloadBase: URL?

    private var modelFolder: URL?
    private var model: GLMOCRModel?
    private var loadTask: Task<Void, Error>?

    public init(
        modelID: String = GLMOCRDefaults.modelID,
        revision: String = GLMOCRDefaults.revision,
        downloadGlobs: [String] = GLMOCRDefaults.downloadGlobs,
        downloadBase: URL? = nil,
        store: any ModelStore = HuggingFaceHubModelStore(),
        processor: GLMOCRProcessor = .init()
    ) {
        self.modelID = modelID
        self.revision = revision
        self.downloadGlobs = downloadGlobs
        self.downloadBase = downloadBase
        self.store = store
        self.processor = processor
    }

    public func ensureLoaded(progress: (@Sendable (Progress) -> Void)? = nil) async throws {
        if model != nil { return }
        if let loadTask {
            try await loadTask.value
            return
        }

        let store = store
        let request = ModelSnapshotRequest(modelID: modelID, revision: revision, matchingGlobs: downloadGlobs)
        let downloadBase = downloadBase

        let task = Task {
            let folder = try await store.resolveSnapshot(request, downloadBase: downloadBase, progress: progress)
            let loadedModel = try await GLMOCRModel.load(from: folder)
            self.finishLoad(modelFolder: folder, model: loadedModel)
        }

        loadTask = task
        do {
            try await task.value
        } catch {
            loadTask = nil
            throw error
        }
    }

    public func recognize(_ input: GLMOCRInput, task: OCRTask, options: GenerateOptions) async throws -> OCRResult {
        // Starter behavior: allow “predecodedText” for UI wiring tests even without a model.
        if case let .predecodedText(text) = input {
            return OCRResult(text: text, rawTokens: nil, diagnostics: .init(modelID: modelID, revision: revision))
        }

        let url: URL
        let page: Int
        switch input {
        case let .file(u, p):
            url = u
            page = p
        case .predecodedText:
            fatalError("unreachable")
        }

        guard url.isFileURL else { throw GLMOCRPipelineError.invalidInputURL(url) }

        guard page >= 1 else { throw GLMOCRPipelineError.invalidPDFPageIndex(page) }

        let normalizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory) else {
            throw GLMOCRPipelineError.inputNotFound(normalizedURL)
        }
        if isDirectory.boolValue {
            throw GLMOCRPipelineError.inputIsDirectory(normalizedURL)
        }

        if model == nil, let loadTask {
            try await loadTask.value
        }

        guard let model else { throw GLMOCRPipelineError.modelNotLoaded }

        let prompt = processor.makePrompt(for: task)

        let ciImage: CIImage = if normalizedURL.pathExtension.lowercased() == "pdf" {
            try VisionIO.loadCIImage(fromPDF: normalizedURL, page: page, dpi: 200)
        } else {
            try VisionIO.loadCIImage(from: normalizedURL)
        }

        var imageOptions = GLMOCRImageProcessingOptions()
        if let folder = modelFolder, let meanStd = try? loadMeanStd(from: folder) {
            imageOptions.mean = meanStd.mean
            imageOptions.std = meanStd.std
        }
        let imageProcessor = GLMOCRImageProcessor(options: imageOptions)
        let processed = try imageProcessor.process(ciImage, config: model.config)

        let generator = GreedyGenerator()
        var result = try await generator.run(
            model: model,
            prompt: prompt,
            pixelValues: processed.pixelValues,
            options: options
        )
        result.diagnostics.modelID = modelID
        result.diagnostics.revision = revision
        return result
    }

    private func finishLoad(modelFolder: URL, model: GLMOCRModel) {
        self.modelFolder = modelFolder
        self.model = model
        loadTask = nil
    }

    private struct PreprocessorConfig: Decodable, Sendable {
        var imageMean: [Float]?
        var imageStd: [Float]?

        private enum CodingKeys: String, CodingKey {
            case imageMean = "image_mean"
            case imageStd = "image_std"
        }
    }

    private func loadMeanStd(from modelFolder: URL) throws -> (mean: (Float, Float, Float), std: (Float, Float, Float))? {
        let url = modelFolder.appendingPathComponent("preprocessor_config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(PreprocessorConfig.self, from: data)
        guard let mean = config.imageMean, let std = config.imageStd, mean.count == 3, std.count == 3 else {
            return nil
        }
        return ((mean[0], mean[1], mean[2]), (std[0], std[1], std[2]))
    }
}
