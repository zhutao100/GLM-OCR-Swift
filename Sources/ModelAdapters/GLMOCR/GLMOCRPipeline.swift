import Foundation
import VLMRuntimeKit

public enum GLMOCRPipelineError: Error, Sendable {
    case modelNotLoaded
    case invalidInputURL(URL)
    case inputNotFound(URL)
    case inputIsDirectory(URL)
    case notImplemented(String)
}

/// Input types supported by the pipeline.
public enum GLMOCRInput: Sendable, Equatable {
    case fileURL(URL)
    case predecodedText(String)
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

        if case let .fileURL(url) = input {
            guard url.isFileURL else { throw GLMOCRPipelineError.invalidInputURL(url) }

            let normalizedURL = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory) else {
                throw GLMOCRPipelineError.inputNotFound(normalizedURL)
            }
            if isDirectory.boolValue {
                throw GLMOCRPipelineError.inputIsDirectory(normalizedURL)
            }
        }

        if model == nil, let loadTask {
            try await loadTask.value
        }

        guard let model else { throw GLMOCRPipelineError.modelNotLoaded }

        let prompt = processor.makePrompt(for: task)

        do {
            let generator = GreedyGenerator()
            var result = try await generator.run(model: model, prompt: prompt, options: options)
            result.diagnostics.modelID = modelID
            result.diagnostics.revision = revision
            result.diagnostics.notes.append(
                "NOTE: Generation is not implemented yet; implement GLMOCRModel.generate(...) in Phase 03+."
            )
            return result
        } catch {
            throw GLMOCRPipelineError.notImplemented("GLM-OCR model generation is not implemented yet: \(error)")
        }
    }

    private func finishLoad(modelFolder: URL, model: GLMOCRModel) {
        self.modelFolder = modelFolder
        self.model = model
        loadTask = nil
    }
}
