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
