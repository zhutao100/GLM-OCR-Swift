import Foundation
import MLX
import MLXNN
import VLMRuntimeKit

public enum GLMOCRModelError: Error, Sendable {
    case invalidModelFolder(URL)
    case configurationError(String)
    case tokenizerFailed(String)
    case weightsFailed(String)
    case missingPixelValues
    case notImplemented
}

public struct GLMOCRModel: CausalLM, Sendable {
    final class State: @unchecked Sendable {
        let config: GLMOCRConfig
        let tokenizer: GLMOCRTokenizer
        let core: GLMOCRCoreModel

        init(config: GLMOCRConfig, tokenizer: GLMOCRTokenizer, core: GLMOCRCoreModel) {
            self.config = config
            self.tokenizer = tokenizer
            self.core = core
        }
    }

    private let state: State

    var config: GLMOCRConfig { state.config }

    #if DEBUG
        var _debugCore: GLMOCRCoreModel { state.core }
    #endif

    public static func load(from modelFolder: URL) async throws -> GLMOCRModel {
        guard modelFolder.isFileURL else { throw GLMOCRModelError.invalidModelFolder(modelFolder) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw GLMOCRModelError.invalidModelFolder(modelFolder)
        }

        let config: GLMOCRConfig
        do {
            config = try GLMOCRConfig.load(from: modelFolder)
        } catch {
            throw GLMOCRModelError.configurationError(String(describing: error))
        }

        let tokenizer: GLMOCRTokenizer
        do {
            tokenizer = try await GLMOCRTokenizer.load(from: modelFolder, config: config)
        } catch {
            throw GLMOCRModelError.tokenizerFailed(String(describing: error))
        }

        let core = try GLMOCRCoreModel(
            config: config,
            imageTokenId: tokenizer.specialTokenIDs.imageId,
            videoStartTokenId: config.videoStartTokenId,
            videoEndTokenId: config.videoEndTokenId
        )

        do {
            let loader = WeightsLoader()
            let wantFloat16 = ProcessInfo.processInfo.environment["GLMOCR_RUN_GOLDEN"] == "1"
            let weightsDType: DType? = wantFloat16 ? .float16 : nil
            var weights = try loader.loadAll(from: modelFolder, dtype: weightsDType)

            // Filter out MTP/aux weights not wired in Phase 02.
            weights = weights.filter { k, _ in !k.hasPrefix("model.language_model.layers.16.") }

            // Convert PyTorch conv weight layouts (O,I,...) to MLX (O,...,I).
            if let patchWeight = weights["model.visual.patch_embed.proj.weight"] {
                weights["model.visual.patch_embed.proj.weight"] = patchWeight.transposed(0, 2, 3, 4, 1)
            }
            if let downsampleWeight = weights["model.visual.downsample.weight"] {
                weights["model.visual.downsample.weight"] = downsampleWeight.transposed(0, 2, 3, 1)
            }

            let parameters = ModuleParameters.unflattened(weights)
            try core.update(parameters: parameters, verify: Module.VerifyUpdate.all)
            try checkedEval(core)
        } catch {
            throw GLMOCRModelError.weightsFailed(String(describing: error))
        }

        return GLMOCRModel(state: State(config: config, tokenizer: tokenizer, core: core))
    }

    public func forward(inputIds: MLXArray, pixelValues: MLXArray?) throws -> MLXArray {
        try state.core.forward(inputIds: inputIds, pixelValues: pixelValues)
    }

    public func generate(
        prompt: String,
        pixelValues: MLXArray?,
        options: GenerateOptions
    ) async throws -> (text: String, tokenIDs: [Int]?) {
        guard let pixelValues else { throw GLMOCRModelError.missingPixelValues }
        guard options.maxNewTokens > 0 else { return ("", []) }

        let tokenizer = state.tokenizer
        let ids = tokenizer.specialTokenIDs
        let stopTokenIDs = Self.stopTokenIDs(config: config, ids: ids)

        // Encode vision once; its token count determines how many <|image|> placeholders are required.
        let visionEmbeddings = state.core.model.visual(pixelValues)
        try checkedEval(visionEmbeddings)
        let numImageTokens = visionEmbeddings.dim(1)

        let chat = GLMOCRChatTemplate(imagePlaceholder: "<image>", appendNoThink: true)
        let promptTokenIDs = try chat.buildInputIDs(prompt: prompt, tokenizer: tokenizer, numImageTokens: numImageTokens)

        let caches = state.core.model.languageModel.layers.map { _ in KVCacheSimple() }

        // Prompt fill (cache all layers).
        let promptIdArray = MLXArray(promptTokenIDs.map { Int32($0) }).reshaped(1, -1)
        let textEmbeddings = state.core.model.languageModel.embed(promptIdArray)
        let fusedEmbeddings = try state.core.fuseEmbeddings(
            inputIds: promptIdArray,
            textEmbeddings: textEmbeddings,
            visionEmbeddings: visionEmbeddings
        )

        let patchSize = max(state.core.model.visual.patchSize, 1)
        let temporalPatchSize = max(state.core.model.visual.temporalPatchSize, 1)
        let gridT = max(pixelValues.dim(1) / temporalPatchSize, 1)
        let gridH = max(pixelValues.dim(2) / patchSize, 1)
        let gridW = max(pixelValues.dim(3) / patchSize, 1)

        let rope = try GLMOCRRoPEIndex.compute(
            inputIds: promptIdArray,
            imageGridTHW: (t: gridT, h: gridH, w: gridW),
            spatialMergeSize: state.core.model.visual.spatialMergeSize,
            imageTokenId: state.core.imageTokenId,
            videoStartTokenId: state.core.videoStartTokenId,
            videoEndTokenId: state.core.videoEndTokenId
        )

        var logits = state.core.forward(
            fusedEmbeddings: fusedEmbeddings,
            mask: .causal,
            caches: caches,
            positionIds: rope.positionIds
        )
        try checkedEval(logits)

        var nextTokenId = Int(logits[0, -1].argMax().item(Int.self))
        var generated: [Int] = []
        generated.reserveCapacity(min(options.maxNewTokens, 512))

        for _ in 0 ..< options.maxNewTokens {
            try Task.checkCancellation()

            if stopTokenIDs.contains(nextTokenId) { break }
            generated.append(nextTokenId)

            let tokenArray = MLXArray([Int32(nextTokenId)]).reshaped(1, 1)
            let nextEmbeddings = state.core.model.languageModel.embed(tokenArray)

            let cachePosition = caches.first?.offset ?? 0
            let delta = rope.ropeDeltas.asType(.int32) + Int32(cachePosition)
            let stepPositionIds = broadcast(delta.reshaped(1, 1, 1), to: [3, 1, 1])

            let nextHidden = state.core.model.languageModel.decode(
                nextEmbeddings,
                mask: .none,
                caches: caches,
                positionIds: stepPositionIds
            )
            logits = state.core.lmHead(nextHidden)
            try checkedEval(logits)
            nextTokenId = Int(logits[0, -1].argMax().item(Int.self))
        }

        let text = tokenizer.tokenizer.decode(tokens: generated, skipSpecialTokens: true)
        return (text, generated)
    }

    static func stopTokenIDs(config: GLMOCRConfig, ids: GLMOCRSpecialTokenIDs) -> Set<Int> {
        let configured = (config.textConfig.eosTokenId ?? []).filter { $0 >= 0 }
        var stop = Set(configured)
        stop.insert(ids.eosId)
        return stop
    }
}
