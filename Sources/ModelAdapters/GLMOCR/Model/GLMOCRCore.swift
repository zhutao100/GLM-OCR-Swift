import Foundation
import MLX
import MLXNN

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
        let textEmbeddings = model.languageModel.embed(inputIds)

        let fusedEmbeddings: MLXArray
        if let pixelValues {
            let visionEmbeddings = model.visual(pixelValues)
            fusedEmbeddings = try GLMOCRFusion.fuse(
                inputIds: inputIds,
                textEmbeddings: textEmbeddings,
                visionEmbeddings: visionEmbeddings,
                imageTokenId: imageTokenId
            )
        } else {
            fusedEmbeddings = textEmbeddings
        }

        let hidden = model.languageModel.decode(fusedEmbeddings)
        return lmHead(hidden)
    }
}
