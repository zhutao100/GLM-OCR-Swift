import Foundation
import MLX
import MLXNN
import VLMRuntimeKit

final class GLMOCRInnerModel: Module {
    @ModuleInfo(key: "language_model") var languageModel: GLMOCRLanguageModel
    @ModuleInfo(key: "visual") var visual: GLMOCRVisionModel

    init(config: GLMOCRConfig) throws {
        _languageModel.wrappedValue = try GLMOCRLanguageModel(config: config.textConfig)
        _visual.wrappedValue = try GLMOCRVisionModel(config: config.visionConfig)
        super.init()
    }
}

final class GLMOCRCoreModel: Module {
    @ModuleInfo(key: "model") var model: GLMOCRInnerModel
    @ModuleInfo(key: "lm_head") var lmHead: Linear

    let imageTokenId: Int
    let videoStartTokenId: Int?
    let videoEndTokenId: Int?

    init(config: GLMOCRConfig, imageTokenId: Int, videoStartTokenId: Int?, videoEndTokenId: Int?) throws {
        guard let hiddenSize = config.textConfig.hiddenSize else {
            throw GLMOCRModelError.configurationError("text_config.hidden_size missing")
        }
        guard let vocabSize = config.textConfig.vocabSize else {
            throw GLMOCRModelError.configurationError("text_config.vocab_size missing")
        }

        self.imageTokenId = imageTokenId
        self.videoStartTokenId = videoStartTokenId
        self.videoEndTokenId = videoEndTokenId
        _model.wrappedValue = try GLMOCRInnerModel(config: config)
        _lmHead.wrappedValue = Linear(hiddenSize, vocabSize, bias: false)
        super.init()
    }

    func forward(inputIds: MLXArray, pixelValues: MLXArray?) throws -> MLXArray {
        let visionEmbeddings = pixelValues.map { model.visual($0) }

        var positionIds: MLXArray?
        if let pixelValues {
            let patchSize = max(model.visual.patchSize, 1)
            let temporalPatchSize = max(model.visual.temporalPatchSize, 1)
            let gridT = max(pixelValues.dim(1) / temporalPatchSize, 1)
            let gridH = max(pixelValues.dim(2) / patchSize, 1)
            let gridW = max(pixelValues.dim(3) / patchSize, 1)

            let rope = try GLMOCRRoPEIndex.compute(
                inputIds: inputIds,
                imageGridTHW: (t: gridT, h: gridH, w: gridW),
                spatialMergeSize: model.visual.spatialMergeSize,
                imageTokenId: imageTokenId,
                videoStartTokenId: videoStartTokenId,
                videoEndTokenId: videoEndTokenId
            )
            positionIds = rope.positionIds
        }

        return try forward(inputIds: inputIds, visionEmbeddings: visionEmbeddings, positionIds: positionIds)
    }

    func forward(inputIds: MLXArray, visionEmbeddings: MLXArray?, positionIds: MLXArray?) throws -> MLXArray {
        let textEmbeddings = model.languageModel.embed(inputIds)
        let fusedEmbeddings = try fuseEmbeddings(
            inputIds: inputIds,
            textEmbeddings: textEmbeddings,
            visionEmbeddings: visionEmbeddings
        )

        let hidden = model.languageModel.decode(fusedEmbeddings, mask: .causal, caches: nil, positionIds: positionIds)
        return lmHead(hidden)
    }

    func forward(
        fusedEmbeddings: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        caches: [KVCacheSimple]?,
        positionIds: MLXArray?
    ) -> MLXArray {
        let hidden = model.languageModel.decode(fusedEmbeddings, mask: mask, caches: caches, positionIds: positionIds)
        return lmHead(hidden)
    }

    func fuseEmbeddings(inputIds: MLXArray, textEmbeddings: MLXArray, visionEmbeddings: MLXArray?) throws -> MLXArray {
        if let visionEmbeddings {
            return try GLMOCRFusion.fuse(
                inputIds: inputIds,
                textEmbeddings: textEmbeddings,
                visionEmbeddings: visionEmbeddings,
                imageTokenId: imageTokenId
            )
        }
        return textEmbeddings
    }
}
