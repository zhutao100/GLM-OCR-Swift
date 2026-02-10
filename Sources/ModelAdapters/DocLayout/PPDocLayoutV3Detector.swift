import CoreImage
import Foundation
import VLMRuntimeKit

public actor PPDocLayoutV3Detector {
    private let store: any ModelStore

    private let modelID: String
    private let revision: String
    private let downloadGlobs: [String]
    private let downloadBase: URL?

    private var modelFolder: URL?
    private var config: PPDocLayoutV3Config?
    private var preprocessorConfig: PPDocLayoutV3PreprocessorConfig?
    private var weightsInventory: PPDocLayoutV3Weights.Inventory?
    private var model: PPDocLayoutV3Model?

    private var loadTask: Task<Void, Error>?

    public init(
        modelID: String = PPDocLayoutV3Defaults.modelID,
        revision: String = PPDocLayoutV3Defaults.revision,
        downloadGlobs: [String] = PPDocLayoutV3Defaults.downloadGlobs,
        downloadBase: URL? = nil,
        store: any ModelStore = HuggingFaceHubModelStore()
    ) {
        self.modelID = modelID
        self.revision = revision
        self.downloadGlobs = downloadGlobs
        self.downloadBase = downloadBase
        self.store = store
    }

    public func ensureLoaded(progress: (@Sendable (Progress) -> Void)? = nil) async throws {
        if weightsInventory != nil { return }
        if let loadTask {
            try await loadTask.value
            return
        }

        let store = store
        let request = ModelSnapshotRequest(modelID: modelID, revision: revision, matchingGlobs: downloadGlobs)
        let downloadBase = downloadBase

        let task = Task {
            let folder = try await store.resolveSnapshot(request, downloadBase: downloadBase, progress: progress)
            let loadedConfig = try PPDocLayoutV3Config.load(from: folder)
            let loadedPreprocessorConfig = try PPDocLayoutV3PreprocessorConfig.load(from: folder)
            let inventory = try PPDocLayoutV3Weights.loadInventory(from: folder)
            try PPDocLayoutV3Weights.validate(inventory)
            finishLoad(
                modelFolder: folder,
                config: loadedConfig,
                preprocessorConfig: loadedPreprocessorConfig,
                weightsInventory: inventory
            )
        }

        loadTask = task
        do {
            try await task.value
        } catch {
            loadTask = nil
            throw error
        }
    }

    public func snapshotFolder() -> URL? { modelFolder }
    public func loadedConfig() -> PPDocLayoutV3Config? { config }
    public func loadedPreprocessorConfig() -> PPDocLayoutV3PreprocessorConfig? { preprocessorConfig }

    public func detect(ciImage: CIImage) async throws -> [OCRRegion] {
        try await ensureLoaded()

        guard let modelFolder else { throw PPDocLayoutV3ModelError.invalidConfiguration("snapshot folder is not loaded") }
        guard let config else { throw PPDocLayoutV3ModelError.invalidConfiguration("config.json is not loaded") }

        if model == nil {
            model = try PPDocLayoutV3Model.load(from: modelFolder)
        }
        guard let model else { throw PPDocLayoutV3ModelError.invalidConfiguration("model failed to load") }

        let processor = PPDocLayoutV3Processor(dtype: .bfloat16)
        let processed = try processor.process(ciImage, preprocessorConfig: preprocessorConfig)

        let raw = try model.forward(pixelValues: processed.pixelValues, options: .init(scoreThreshold: 0.3))
        let (regions, diagnostics) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(applyNMS: true, mergeModeByClassID: PPDocLayoutV3Postprocess.defaultMergeModeByClassID)
        )

        #if DEBUG
            if !diagnostics.isEmpty {
                for note in diagnostics {
                    print("PPDocLayoutV3Postprocess: \(note)")
                }
            }
        #endif

        var output: [OCRRegion] = []
        output.reserveCapacity(regions.count)

        for region in regions {
            if region.taskType == .abandon { continue }

            let kind = PPDocLayoutV3Mappings.labelToVisualizationKind[region.nativeLabel] ?? .unknown
            let content: String? = nil // filled by OCR stage; kept nil for skipped regions too

            output.append(
                OCRRegion(
                    index: output.count,
                    kind: kind,
                    nativeLabel: region.nativeLabel,
                    bbox: region.bbox,
                    polygon: region.polygon,
                    content: content
                )
            )
        }

        return output
    }

    private func finishLoad(
        modelFolder: URL,
        config: PPDocLayoutV3Config,
        preprocessorConfig: PPDocLayoutV3PreprocessorConfig?,
        weightsInventory: PPDocLayoutV3Weights.Inventory
    ) {
        self.modelFolder = modelFolder
        self.config = config
        self.preprocessorConfig = preprocessorConfig
        self.weightsInventory = weightsInventory
        loadTask = nil
    }
}
