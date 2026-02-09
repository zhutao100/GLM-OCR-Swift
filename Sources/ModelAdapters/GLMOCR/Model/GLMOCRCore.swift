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

    init(config: GLMOCRConfig, imageTokenId: Int) throws {
        guard let hiddenSize = config.textConfig.hiddenSize else {
            throw GLMOCRModelError.configurationError("text_config.hidden_size missing")
        }
        guard let vocabSize = config.textConfig.vocabSize else {
            throw GLMOCRModelError.configurationError("text_config.vocab_size missing")
        }

        self.imageTokenId = imageTokenId
        _model.wrappedValue = try GLMOCRInnerModel(config: config)
        _lmHead.wrappedValue = Linear(hiddenSize, vocabSize, bias: false)
        super.init()
    }

    func forward(inputIds: MLXArray, pixelValues: MLXArray?) throws -> MLXArray {
        let visionEmbeddings = pixelValues.map { model.visual($0) }
        return try forward(inputIds: inputIds, visionEmbeddings: visionEmbeddings)
    }

    func forward(inputIds: MLXArray, visionEmbeddings: MLXArray?) throws -> MLXArray {
        let textEmbeddings = model.languageModel.embed(inputIds)
        let fusedEmbeddings = try fuseEmbeddings(
            inputIds: inputIds,
            textEmbeddings: textEmbeddings,
            visionEmbeddings: visionEmbeddings
        )

        let hidden = model.languageModel.decode(fusedEmbeddings)
        return lmHead(hidden)
    }

    func forward(
        fusedEmbeddings: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        caches: [KVCacheSimple]?
    ) -> MLXArray {
        let hidden = model.languageModel.decode(fusedEmbeddings, mask: mask, caches: caches)
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
