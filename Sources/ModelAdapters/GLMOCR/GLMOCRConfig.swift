import Foundation

public struct GLMOCRConfig: Sendable, Codable, Equatable {
    public struct RopeParameters: Sendable, Codable, Equatable {
        public var ropeType: String?
        public var mropeSection: [Int]?
        public var partialRotaryFactor: Float?
        public var ropeTheta: Float?

        public init(
            ropeType: String? = nil,
            mropeSection: [Int]? = nil,
            partialRotaryFactor: Float? = nil,
            ropeTheta: Float? = nil
        ) {
            self.ropeType = ropeType
            self.mropeSection = mropeSection
            self.partialRotaryFactor = partialRotaryFactor
            self.ropeTheta = ropeTheta
        }
    }

    public struct TextConfig: Sendable, Codable, Equatable {
        public var modelType: String?
        public var padTokenId: Int?
        public var vocabSize: Int?
        public var eosTokenId: [Int]?

        public var attentionBias: Bool?
        public var attentionDropout: Float?

        public var headDim: Int?
        public var hiddenAct: String?
        public var hiddenSize: Int?
        public var intermediateSize: Int?
        public var maxPositionEmbeddings: Int?

        public var numAttentionHeads: Int?
        public var numHiddenLayers: Int?
        public var numKeyValueHeads: Int?
        public var numNextnPredictLayers: Int?

        public var rmsNormEps: Float?
        public var ropeParameters: RopeParameters?

        public var tieWordEmbeddings: Bool?
        public var useCache: Bool?
        public var dtype: String?

        public init(
            modelType: String? = nil,
            padTokenId: Int? = nil,
            vocabSize: Int? = nil,
            eosTokenId: [Int]? = nil,
            attentionBias: Bool? = nil,
            attentionDropout: Float? = nil,
            headDim: Int? = nil,
            hiddenAct: String? = nil,
            hiddenSize: Int? = nil,
            intermediateSize: Int? = nil,
            maxPositionEmbeddings: Int? = nil,
            numAttentionHeads: Int? = nil,
            numHiddenLayers: Int? = nil,
            numKeyValueHeads: Int? = nil,
            numNextnPredictLayers: Int? = nil,
            rmsNormEps: Float? = nil,
            ropeParameters: RopeParameters? = nil,
            tieWordEmbeddings: Bool? = nil,
            useCache: Bool? = nil,
            dtype: String? = nil
        ) {
            self.modelType = modelType
            self.padTokenId = padTokenId
            self.vocabSize = vocabSize
            self.eosTokenId = eosTokenId
            self.attentionBias = attentionBias
            self.attentionDropout = attentionDropout
            self.headDim = headDim
            self.hiddenAct = hiddenAct
            self.hiddenSize = hiddenSize
            self.intermediateSize = intermediateSize
            self.maxPositionEmbeddings = maxPositionEmbeddings
            self.numAttentionHeads = numAttentionHeads
            self.numHiddenLayers = numHiddenLayers
            self.numKeyValueHeads = numKeyValueHeads
            self.numNextnPredictLayers = numNextnPredictLayers
            self.rmsNormEps = rmsNormEps
            self.ropeParameters = ropeParameters
            self.tieWordEmbeddings = tieWordEmbeddings
            self.useCache = useCache
            self.dtype = dtype
        }
    }

    public struct VisionConfig: Sendable, Codable, Equatable {
        public var modelType: String?
        public var hiddenSize: Int?
        public var depth: Int?
        public var numHeads: Int?

        public var attentionBias: Bool?
        public var intermediateSize: Int?
        public var hiddenAct: String?
        public var hiddenDropoutProb: Float?

        public var imageSize: Int?
        public var patchSize: Int?
        public var temporalPatchSize: Int?
        public var spatialMergeSize: Int?

        public var outHiddenSize: Int?
        public var rmsNormEps: Float?
        public var initializerRange: Float?

        public init(
            modelType: String? = nil,
            hiddenSize: Int? = nil,
            depth: Int? = nil,
            numHeads: Int? = nil,
            attentionBias: Bool? = nil,
            intermediateSize: Int? = nil,
            hiddenAct: String? = nil,
            hiddenDropoutProb: Float? = nil,
            imageSize: Int? = nil,
            patchSize: Int? = nil,
            temporalPatchSize: Int? = nil,
            spatialMergeSize: Int? = nil,
            outHiddenSize: Int? = nil,
            rmsNormEps: Float? = nil,
            initializerRange: Float? = nil
        ) {
            self.modelType = modelType
            self.hiddenSize = hiddenSize
            self.depth = depth
            self.numHeads = numHeads
            self.attentionBias = attentionBias
            self.intermediateSize = intermediateSize
            self.hiddenAct = hiddenAct
            self.hiddenDropoutProb = hiddenDropoutProb
            self.imageSize = imageSize
            self.patchSize = patchSize
            self.temporalPatchSize = temporalPatchSize
            self.spatialMergeSize = spatialMergeSize
            self.outHiddenSize = outHiddenSize
            self.rmsNormEps = rmsNormEps
            self.initializerRange = initializerRange
        }
    }

    public var architectures: [String]?
    public var modelType: String?

    public var textConfig: TextConfig
    public var visionConfig: VisionConfig

    public var imageStartTokenId: Int?
    public var imageEndTokenId: Int?
    public var imageTokenId: Int?

    public var videoStartTokenId: Int?
    public var videoEndTokenId: Int?
    public var videoTokenId: Int?

    public var transformersVersion: String?

    public init(
        architectures: [String]? = nil,
        modelType: String? = nil,
        textConfig: TextConfig,
        visionConfig: VisionConfig,
        imageStartTokenId: Int? = nil,
        imageEndTokenId: Int? = nil,
        imageTokenId: Int? = nil,
        videoStartTokenId: Int? = nil,
        videoEndTokenId: Int? = nil,
        videoTokenId: Int? = nil,
        transformersVersion: String? = nil
    ) {
        self.architectures = architectures
        self.modelType = modelType
        self.textConfig = textConfig
        self.visionConfig = visionConfig
        self.imageStartTokenId = imageStartTokenId
        self.imageEndTokenId = imageEndTokenId
        self.imageTokenId = imageTokenId
        self.videoStartTokenId = videoStartTokenId
        self.videoEndTokenId = videoEndTokenId
        self.videoTokenId = videoTokenId
        self.transformersVersion = transformersVersion
    }

    private enum CodingKeys: String, CodingKey {
        case architectures
        case modelType = "model_type"
        case textConfig = "text_config"
        case visionConfig = "vision_config"
        case imageStartTokenId = "image_start_token_id"
        case imageEndTokenId = "image_end_token_id"
        case imageTokenId = "image_token_id"
        case videoStartTokenId = "video_start_token_id"
        case videoEndTokenId = "video_end_token_id"
        case videoTokenId = "video_token_id"
        case transformersVersion = "transformers_version"
    }

    public static func load(from modelFolder: URL) throws -> GLMOCRConfig {
        let url = modelFolder.appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GLMOCRConfig.self, from: data)
    }
}

extension GLMOCRConfig.TextConfig {
    private enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case padTokenId = "pad_token_id"
        case vocabSize = "vocab_size"
        case eosTokenId = "eos_token_id"
        case attentionBias = "attention_bias"
        case attentionDropout = "attention_dropout"
        case headDim = "head_dim"
        case hiddenAct = "hidden_act"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case maxPositionEmbeddings = "max_position_embeddings"
        case numAttentionHeads = "num_attention_heads"
        case numHiddenLayers = "num_hidden_layers"
        case numNextnPredictLayers = "num_nextn_predict_layers"
        case numKeyValueHeads = "num_key_value_heads"
        case rmsNormEps = "rms_norm_eps"
        case dtype
        case ropeParameters = "rope_parameters"
        case tieWordEmbeddings = "tie_word_embeddings"
        case useCache = "use_cache"
    }
}

extension GLMOCRConfig.RopeParameters {
    private enum CodingKeys: String, CodingKey {
        case ropeType = "rope_type"
        case mropeSection = "mrope_section"
        case partialRotaryFactor = "partial_rotary_factor"
        case ropeTheta = "rope_theta"
    }
}

extension GLMOCRConfig.VisionConfig {
    private enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case depth
        case numHeads = "num_heads"
        case attentionBias = "attention_bias"
        case intermediateSize = "intermediate_size"
        case hiddenAct = "hidden_act"
        case hiddenDropoutProb = "hidden_dropout_prob"
        case initializerRange = "initializer_range"
        case imageSize = "image_size"
        case patchSize = "patch_size"
        case outHiddenSize = "out_hidden_size"
        case rmsNormEps = "rms_norm_eps"
        case spatialMergeSize = "spatial_merge_size"
        case temporalPatchSize = "temporal_patch_size"
    }
}
