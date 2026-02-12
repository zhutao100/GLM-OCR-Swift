// swiftlint:disable file_length
import Foundation
import MLX
import MLXNN
import VLMRuntimeKit

public enum PPDocLayoutV3ModelError: Error, Sendable, Equatable {
    case invalidModelFolder(URL)
    case configurationError(String)
    case missingWeight(String)
    case incompatibleWeightShape(String)
    case weightsFailed(String)
    case invalidConfiguration(String)
}

public struct PPDocLayoutV3Model: Sendable {
    public struct Options: Sendable, Equatable {
        public var scoreThreshold: Float

        public init(scoreThreshold: Float = 0.3) {
            self.scoreThreshold = scoreThreshold
        }
    }

    struct RawOutputs: @unchecked Sendable {
        var logits: MLXArray
        var predBoxes: MLXArray
        var orderLogits: MLXArray
        var encoderTopKIndices: MLXArray
        var didFallbackToAllQueries: Bool
    }

    final class State: @unchecked Sendable {
        let config: PPDocLayoutV3Config
        let modelConfig: PPDocLayoutV3ModelConfig
        let core: PPDocLayoutV3Root

        init(config: PPDocLayoutV3Config, modelConfig: PPDocLayoutV3ModelConfig, core: PPDocLayoutV3Root) {
            self.config = config
            self.modelConfig = modelConfig
            self.core = core
        }
    }

    private let state: State

    private init(state: State) {
        self.state = state
    }

    public static func load(from modelFolder: URL, weightsDTypeOverride: DType? = nil) throws -> PPDocLayoutV3Model {
        guard modelFolder.isFileURL else { throw PPDocLayoutV3ModelError.invalidModelFolder(modelFolder) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw PPDocLayoutV3ModelError.invalidModelFolder(modelFolder)
        }

        let config: PPDocLayoutV3Config
        let modelConfig: PPDocLayoutV3ModelConfig
        do {
            config = try PPDocLayoutV3Config.load(from: modelFolder)
            modelConfig = try PPDocLayoutV3ModelConfig.load(from: modelFolder)
        } catch {
            throw PPDocLayoutV3ModelError.configurationError(String(describing: error))
        }

        let numLabels = config.id2label.count
        guard numLabels > 0 else {
            throw PPDocLayoutV3ModelError.invalidConfiguration("id2label is empty; cannot determine num_labels")
        }

        let core = PPDocLayoutV3Root(modelConfig: modelConfig, numLabels: numLabels)
        core.train(false)

        do {
            let loader = WeightsLoader()
            let wantFloat16 = ProcessInfo.processInfo.environment["LAYOUT_RUN_GOLDEN"] == "1"
            let weightsDType: DType = if let weightsDTypeOverride {
                weightsDTypeOverride
            } else if let raw = ProcessInfo.processInfo.environment["LAYOUT_WEIGHTS_DTYPE"]?.lowercased() {
                switch raw {
                case "float16", "fp16":
                    .float16
                case "float32", "fp32":
                    .float32
                case "bfloat16", "bf16":
                    .bfloat16
                default:
                    wantFloat16 ? .float16 : .float32
                }
            } else {
                wantFloat16 ? .float16 : .float32
            }
            var weights = try loader.loadAll(from: modelFolder, dtype: weightsDType)

            // Convert PyTorch conv weight layouts (O, I, kH, kW) to MLX (O, kH, kW, I).
            for (key, value) in weights where value.ndim == 4 {
                weights[key] = value.transposed(0, 2, 3, 1)
            }

            let parameters = ModuleParameters.unflattened(weights)
            try core.update(parameters: parameters, verify: [.allModelKeysSet, .shapeMismatch])
            try checkedEval(core)
        } catch let error as UpdateError {
            switch error {
            case let .keyNotFound(path, _):
                throw PPDocLayoutV3ModelError.missingWeight(path.joined(separator: "."))
            case let .mismatchedSize(path, _, expectedShape, actualShape):
                throw PPDocLayoutV3ModelError.incompatibleWeightShape(
                    "\(path.joined(separator: ".")) expected \(expectedShape) but got \(actualShape)"
                )
            default:
                throw PPDocLayoutV3ModelError.weightsFailed(String(describing: error))
            }
        } catch {
            throw PPDocLayoutV3ModelError.weightsFailed(String(describing: error))
        }

        return PPDocLayoutV3Model(state: State(config: config, modelConfig: modelConfig, core: core))
    }

    public func forward(pixelValues: MLXArray, options: Options = .init()) throws -> PPDocLayoutV3Postprocess.RawDetections {
        try state.core.forward(pixelValues: pixelValues, options: options)
    }

    func forwardRawOutputs(
        pixelValues: MLXArray,
        options: Options = .init(),
        encoderTopKIndicesOverride: [Int]? = nil,
        probe: PPDocLayoutV3IntermediateProbe? = nil
    ) throws -> RawOutputs {
        try state.core.forwardRawOutputs(
            pixelValues: pixelValues,
            options: options,
            encoderTopKIndicesOverride: encoderTopKIndicesOverride,
            probe: probe
        )
    }
}

// MARK: - Config

public struct PPDocLayoutV3ModelConfig: Sendable, Codable, Equatable {
    public var dModel: Int
    public var numQueries: Int

    public var encoderHiddenDim: Int
    public var encoderInChannels: [Int]
    public var encoderLayers: Int
    public var encoderAttentionHeads: Int
    public var encoderFFNDim: Int
    public var encoderActivationFunction: String

    public var decoderInChannels: [Int]
    public var decoderLayers: Int
    public var decoderAttentionHeads: Int
    public var decoderFFNDim: Int
    public var decoderNPoints: Int
    public var decoderActivationFunction: String

    public var numFeatureLevels: Int
    public var featureStrides: [Int]
    public var encodeProjLayers: [Int]
    public var positionalEncodingTemperature: Int

    public var activationFunction: String
    public var normalizeBefore: Bool

    public var dropout: Double
    public var attentionDropout: Double
    public var activationDropout: Double

    public var batchNormEps: Double?
    public var layerNormEps: Double?
    public var disableCustomKernels: Bool

    public var hiddenExpansion: Double

    public var maskFeatureChannels: [Int]
    public var x4FeatDim: Int
    public var maskEnhanced: Bool
    public var numPrototypes: Int

    public var globalPointerHeadSize: Int
    public var gpDropoutValue: Double?

    private enum CodingKeys: String, CodingKey {
        case dModel = "d_model"
        case numQueries = "num_queries"

        case encoderHiddenDim = "encoder_hidden_dim"
        case encoderInChannels = "encoder_in_channels"
        case encoderLayers = "encoder_layers"
        case encoderAttentionHeads = "encoder_attention_heads"
        case encoderFFNDim = "encoder_ffn_dim"
        case encoderActivationFunction = "encoder_activation_function"

        case decoderInChannels = "decoder_in_channels"
        case decoderLayers = "decoder_layers"
        case decoderAttentionHeads = "decoder_attention_heads"
        case decoderFFNDim = "decoder_ffn_dim"
        case decoderNPoints = "decoder_n_points"
        case decoderActivationFunction = "decoder_activation_function"

        case numFeatureLevels = "num_feature_levels"
        case featureStrides = "feature_strides"
        case encodeProjLayers = "encode_proj_layers"
        case positionalEncodingTemperature = "positional_encoding_temperature"

        case activationFunction = "activation_function"
        case normalizeBefore = "normalize_before"

        case dropout
        case attentionDropout = "attention_dropout"
        case activationDropout = "activation_dropout"

        case batchNormEps = "batch_norm_eps"
        case layerNormEps = "layer_norm_eps"
        case disableCustomKernels = "disable_custom_kernels"

        case hiddenExpansion = "hidden_expansion"

        case maskFeatureChannels = "mask_feature_channels"
        case x4FeatDim = "x4_feat_dim"
        case maskEnhanced = "mask_enhanced"
        case numPrototypes = "num_prototypes"

        case globalPointerHeadSize = "global_pointer_head_size"
        case gpDropoutValue = "gp_dropout_value"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        dModel = try container.decode(Int.self, forKey: .dModel)
        numQueries = try container.decode(Int.self, forKey: .numQueries)

        encoderHiddenDim = try container.decodeIfPresent(Int.self, forKey: .encoderHiddenDim) ?? dModel
        encoderInChannels = try container.decodeIfPresent([Int].self, forKey: .encoderInChannels) ?? [512, 1024, 2048]
        encoderLayers = try container.decodeIfPresent(Int.self, forKey: .encoderLayers) ?? 0
        encoderAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .encoderAttentionHeads) ?? 8
        encoderFFNDim = try container.decodeIfPresent(Int.self, forKey: .encoderFFNDim) ?? 1024
        encoderActivationFunction = try container.decodeIfPresent(String.self, forKey: .encoderActivationFunction) ?? "gelu"

        decoderInChannels = try container.decodeIfPresent([Int].self, forKey: .decoderInChannels) ?? Array(repeating: dModel, count: 3)
        decoderLayers = try container.decodeIfPresent(Int.self, forKey: .decoderLayers) ?? 1
        decoderAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .decoderAttentionHeads) ?? 8
        decoderFFNDim = try container.decodeIfPresent(Int.self, forKey: .decoderFFNDim) ?? 1024
        decoderNPoints = try container.decodeIfPresent(Int.self, forKey: .decoderNPoints) ?? 4
        decoderActivationFunction = try container.decodeIfPresent(String.self, forKey: .decoderActivationFunction) ?? "relu"

        numFeatureLevels = try container.decodeIfPresent(Int.self, forKey: .numFeatureLevels) ?? decoderInChannels.count
        featureStrides = try container.decodeIfPresent([Int].self, forKey: .featureStrides) ?? [8, 16, 32]
        encodeProjLayers = try container.decodeIfPresent([Int].self, forKey: .encodeProjLayers) ?? []
        positionalEncodingTemperature = try container.decodeIfPresent(Int.self, forKey: .positionalEncodingTemperature) ?? 10000

        activationFunction = try container.decodeIfPresent(String.self, forKey: .activationFunction) ?? "silu"
        normalizeBefore = try container.decodeIfPresent(Bool.self, forKey: .normalizeBefore) ?? false

        dropout = try container.decodeIfPresent(Double.self, forKey: .dropout) ?? 0
        attentionDropout = try container.decodeIfPresent(Double.self, forKey: .attentionDropout) ?? 0
        activationDropout = try container.decodeIfPresent(Double.self, forKey: .activationDropout) ?? 0

        batchNormEps = try container.decodeIfPresent(Double.self, forKey: .batchNormEps)
        layerNormEps = try container.decodeIfPresent(Double.self, forKey: .layerNormEps)
        disableCustomKernels = try container.decodeIfPresent(Bool.self, forKey: .disableCustomKernels) ?? true

        hiddenExpansion = try container.decodeIfPresent(Double.self, forKey: .hiddenExpansion) ?? 1.0

        maskFeatureChannels = try container.decodeIfPresent([Int].self, forKey: .maskFeatureChannels) ?? [64, 64]
        x4FeatDim = try container.decodeIfPresent(Int.self, forKey: .x4FeatDim) ?? 128
        maskEnhanced = try container.decodeIfPresent(Bool.self, forKey: .maskEnhanced) ?? true
        numPrototypes = try container.decodeIfPresent(Int.self, forKey: .numPrototypes) ?? 32

        globalPointerHeadSize = try container.decodeIfPresent(Int.self, forKey: .globalPointerHeadSize) ?? 64
        gpDropoutValue = try container.decodeIfPresent(Double.self, forKey: .gpDropoutValue)
    }

    public static func load(from modelFolder: URL) throws -> PPDocLayoutV3ModelConfig {
        let url = modelFolder.appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PPDocLayoutV3ModelConfig.self, from: data)
    }
}

// MARK: - Core modules (full)

final class PPDocLayoutV3Root: Module {
    @ModuleInfo(key: "model") var model: PPDocLayoutV3Core

    init(modelConfig: PPDocLayoutV3ModelConfig, numLabels: Int) {
        _model.wrappedValue = PPDocLayoutV3Core(modelConfig: modelConfig, numLabels: numLabels)
        super.init()
    }

    func forward(pixelValues: MLXArray, options: PPDocLayoutV3Model.Options) throws -> PPDocLayoutV3Postprocess.RawDetections {
        try model.forward(pixelValues: pixelValues, options: options)
    }

    func forwardRawOutputs(
        pixelValues: MLXArray,
        options: PPDocLayoutV3Model.Options,
        encoderTopKIndicesOverride: [Int]? = nil,
        probe: PPDocLayoutV3IntermediateProbe? = nil
    ) throws -> PPDocLayoutV3Model.RawOutputs {
        try model.forwardRawOutputs(
            pixelValues: pixelValues,
            options: options,
            encoderTopKIndicesOverride: encoderTopKIndicesOverride,
            probe: probe
        )
    }
}

final class PPDocLayoutV3Core: Module {
    @ModuleInfo(key: "backbone") var backbone: PPDocLayoutV3ConvEncoderCore

    @ModuleInfo(key: "encoder_input_proj") var encoderInputProj: [(Conv2d, BatchNorm)]
    @ModuleInfo(key: "encoder") var encoder: PPDocLayoutV3HybridEncoderCore

    @ModuleInfo(key: "decoder_input_proj") var decoderInputProj: [(Conv2d, BatchNorm)]

    @ModuleInfo(key: "enc_output") var encOutput: (Linear, LayerNorm)
    @ModuleInfo(key: "enc_score_head") var encScoreHead: Linear
    @ModuleInfo(key: "enc_bbox_head") var encBBoxHead: PPMLPPredictionHead

    @ModuleInfo(key: "decoder") var decoder: PPDocLayoutV3DecoderCore
    @ModuleInfo(key: "decoder_norm") var decoderNorm: LayerNorm
    @ModuleInfo(key: "decoder_order_head") var decoderOrderHead: [Linear]
    @ModuleInfo(key: "decoder_global_pointer") var decoderGlobalPointer: PPGlobalPointer

    @ModuleInfo(key: "mask_query_head") var maskQueryHead: PPMLPPredictionHead

    private let modelConfig: PPDocLayoutV3ModelConfig
    private let numLabels: Int

    init(modelConfig: PPDocLayoutV3ModelConfig, numLabels: Int) {
        self.modelConfig = modelConfig
        self.numLabels = numLabels

        _backbone.wrappedValue = PPDocLayoutV3ConvEncoderCore()

        let bnEps = Float(modelConfig.batchNormEps ?? 1e-5)
        _encoderInputProj.wrappedValue = modelConfig.encoderInChannels.map { inChannels in
            (
                Conv2d(
                    inputChannels: inChannels,
                    outputChannels: modelConfig.encoderHiddenDim,
                    kernelSize: 1,
                    stride: 1,
                    padding: 0,
                    bias: false
                ),
                BatchNorm(featureCount: modelConfig.encoderHiddenDim, eps: bnEps)
            )
        }

        _encoder.wrappedValue = PPDocLayoutV3HybridEncoderCore(modelConfig: modelConfig)

        var decoderProj: [(Conv2d, BatchNorm)] = modelConfig.decoderInChannels.map { inChannels in
            (
                Conv2d(
                    inputChannels: inChannels,
                    outputChannels: modelConfig.dModel,
                    kernelSize: 1,
                    stride: 1,
                    padding: 0,
                    bias: false
                ),
                BatchNorm(featureCount: modelConfig.dModel, eps: bnEps)
            )
        }

        var inChannels = modelConfig.dModel
        if modelConfig.numFeatureLevels > decoderProj.count {
            for _ in decoderProj.count ..< modelConfig.numFeatureLevels {
                decoderProj.append(
                    (
                        Conv2d(
                            inputChannels: inChannels,
                            outputChannels: modelConfig.dModel,
                            kernelSize: 3,
                            stride: 2,
                            padding: 1,
                            bias: false
                        ),
                        BatchNorm(featureCount: modelConfig.dModel, eps: bnEps)
                    )
                )
                inChannels = modelConfig.dModel
            }
        }
        _decoderInputProj.wrappedValue = decoderProj

        let lnEps = Float(modelConfig.layerNormEps ?? 1e-5)
        _encOutput.wrappedValue = (
            Linear(modelConfig.dModel, modelConfig.dModel),
            LayerNorm(dimensions: modelConfig.dModel, eps: lnEps)
        )
        _encScoreHead.wrappedValue = Linear(modelConfig.dModel, numLabels)
        _encBBoxHead.wrappedValue = PPMLPPredictionHead(
            inputDim: modelConfig.dModel,
            hiddenDim: modelConfig.dModel,
            outputDim: 4,
            numLayers: 3
        )

        _decoder.wrappedValue = PPDocLayoutV3DecoderCore(modelConfig: modelConfig)
        _decoderNorm.wrappedValue = LayerNorm(dimensions: modelConfig.dModel, eps: lnEps)
        _decoderOrderHead.wrappedValue = (0 ..< max(modelConfig.decoderLayers, 1)).map { _ in
            Linear(modelConfig.dModel, modelConfig.dModel)
        }
        _decoderGlobalPointer.wrappedValue = PPGlobalPointer(dModel: modelConfig.dModel, headSize: modelConfig.globalPointerHeadSize)

        _maskQueryHead.wrappedValue = PPMLPPredictionHead(
            inputDim: modelConfig.dModel,
            hiddenDim: modelConfig.dModel,
            outputDim: modelConfig.numPrototypes,
            numLayers: 3
        )

        super.init()
    }

    func forward(pixelValues: MLXArray, options: PPDocLayoutV3Model.Options) throws -> PPDocLayoutV3Postprocess.RawDetections {
        let raw = try forwardRawOutputs(pixelValues: pixelValues, options: options)

        var detections = postProcessObjectDetection(
            logits: raw.logits,
            boxes: raw.predBoxes,
            orderLogits: raw.orderLogits,
            scoreThreshold: options.scoreThreshold
        )

        if detections.scores.isEmpty {
            detections = postProcessObjectDetection(
                logits: raw.logits,
                boxes: raw.predBoxes,
                orderLogits: raw.orderLogits,
                scoreThreshold: -Float.infinity
            )
        }

        return detections
    }

    func forwardRawOutputs(
        pixelValues: MLXArray,
        options _: PPDocLayoutV3Model.Options,
        encoderTopKIndicesOverride: [Int]? = nil,
        probe: PPDocLayoutV3IntermediateProbe? = nil
    ) throws -> PPDocLayoutV3Model.RawOutputs {
        let pixelValues: MLXArray = if pixelValues.dtype == .bfloat16 { pixelValues.asType(.float32) } else { pixelValues }
        probe?.capture("pixel_values", tensor: pixelValues)

        let features = backbone(pixelValues)
        guard features.count == 4 else {
            throw PPDocLayoutV3ModelError.invalidConfiguration("backbone returned \(features.count) feature maps, expected 4")
        }
        for (idx, feature) in features.enumerated() {
            probe?.capture("backbone.feature_maps.\(idx)", tensor: feature)
        }

        let x4Feat = features[0]
        var projected: [MLXArray] = []
        projected.reserveCapacity(encoderInputProj.count)
        for (idx, feature) in zip(encoderInputProj.indices, features.dropFirst()) {
            let (conv, norm) = encoderInputProj[idx]
            let convOut = conv(feature)
            probe?.capture("encoder_input_proj_conv.\(idx)", tensor: convOut)
            let normOut = norm(convOut)
            probe?.capture("encoder_input_proj.\(idx)", tensor: normOut)
            projected.append(normOut)
        }

        let encoderOutputs = encoder.forward(projected, x4Feat: x4Feat)
        for (idx, feature) in encoderOutputs.featureMaps.enumerated() {
            probe?.capture("hybrid_encoder.feature_maps.\(idx)", tensor: feature)
        }
        probe?.capture("hybrid_encoder.mask_feat", tensor: encoderOutputs.maskFeat)

        var sources: [MLXArray] = []
        sources.reserveCapacity(max(modelConfig.numFeatureLevels, encoderOutputs.featureMaps.count))

        for level in 0 ..< min(encoderOutputs.featureMaps.count, decoderInputProj.count) {
            let (conv, norm) = decoderInputProj[level]
            sources.append(norm(conv(encoderOutputs.featureMaps[level])))
        }

        if modelConfig.numFeatureLevels > sources.count, let last = encoderOutputs.featureMaps.last {
            let start = sources.count
            for level in start ..< min(modelConfig.numFeatureLevels, decoderInputProj.count) {
                let (conv, norm) = decoderInputProj[level]
                sources.append(norm(conv(last)))
            }
        }

        var sourceFlatten: [MLXArray] = []
        sourceFlatten.reserveCapacity(sources.count)

        var spatialShapesList: [(height: Int, width: Int)] = []
        spatialShapesList.reserveCapacity(sources.count)

        let batch = sources.first?.dim(0) ?? 1
        for source in sources {
            let h = source.dim(1)
            let w = source.dim(2)
            spatialShapesList.append((height: h, width: w))
            sourceFlatten.append(source.reshaped(batch, h * w, source.dim(3)))
        }

        let sourceFlat = concatenated(sourceFlatten, axis: 1)
        probe?.capture("source_flatten", tensor: sourceFlat)

        var spatialShapePairs: [Int32] = []
        spatialShapePairs.reserveCapacity(spatialShapesList.count * 2)
        for shape in spatialShapesList {
            spatialShapePairs.append(Int32(shape.height))
            spatialShapePairs.append(Int32(shape.width))
        }
        let spatialShapes = MLXArray(spatialShapePairs).reshaped(spatialShapesList.count, 2)

        var startIndices: [Int32] = []
        startIndices.reserveCapacity(spatialShapesList.count)
        var running: Int32 = 0
        for shape in spatialShapesList {
            startIndices.append(running)
            running += Int32(shape.height * shape.width)
        }
        let levelStartIndex = MLXArray(startIndices)

        let (anchors, validMask) = generateAnchors(
            spatialShapes: spatialShapesList.map { (h: $0.height, w: $0.width) },
            dtype: sourceFlat.dtype
        )
        probe?.capture("anchors", tensor: anchors)
        probe?.capture("valid_mask", tensor: validMask)
        let memory = sourceFlat * validMask.asType(sourceFlat.dtype)
        probe?.capture("memory", tensor: memory)

        let outputMemory = encOutput.1(encOutput.0(memory))
        probe?.capture("output_memory", tensor: outputMemory)
        let encOutputsClass = encScoreHead(outputMemory)
        probe?.capture("enc_outputs_class", tensor: encOutputsClass)
        let encOutputsCoordLogits = encBBoxHead(outputMemory) + anchors
        probe?.capture("enc_outputs_coord_logits", tensor: encOutputsCoordLogits)

        let maxScores = encOutputsClass.max(axis: -1) // [B, S]
        let k = min(modelConfig.numQueries, maxScores.dim(1))
        let stableTopK = ProcessInfo.processInfo.environment["LAYOUT_RUN_GOLDEN"] == "1"

        let topkInd: MLXArray
        if let override = encoderTopKIndicesOverride {
            guard override.count == k else {
                throw PPDocLayoutV3ModelError.invalidConfiguration(
                    "encoderTopKIndicesOverride count \(override.count) does not match expected k=\(k)"
                )
            }
            guard override.allSatisfy({ $0 >= 0 && $0 < maxScores.dim(1) }) else {
                throw PPDocLayoutV3ModelError.invalidConfiguration("encoderTopKIndicesOverride contains out-of-range indices")
            }

            let indices = MLXArray(override.map(Int32.init)).reshaped(1, k)
            topkInd = broadcast(indices, to: [batch, k])
        } else if stableTopK {
            topkInd = stableTopKIndices(maxScores: maxScores, k: k)
        } else {
            let sorted = argSort(-maxScores, axis: 1)
            topkInd = sorted[0..., 0 ..< k]
        }

        let idxBoxes = broadcast(topkInd.expandedDimensions(axis: -1), to: [batch, k, 4])
        let idxHidden = broadcast(topkInd.expandedDimensions(axis: -1), to: [batch, k, modelConfig.dModel])

        let target = takeAlong(outputMemory, idxHidden, axis: 1)

        var referencePointsUnact = takeAlong(encOutputsCoordLogits, idxBoxes, axis: 1)

        if modelConfig.maskEnhanced {
            let outQuery = decoderNorm(target)
            let maskQueryEmbed = maskQueryHead(outQuery)

            let maskFeat = encoderOutputs.maskFeat
            let maskH = maskFeat.dim(1)
            let maskW = maskFeat.dim(2)
            let maskFlat = maskFeat
                .reshaped(batch, maskH * maskW, modelConfig.numPrototypes)
                .transposed(0, 2, 1)

            let encOutMasks = matmul(maskQueryEmbed, maskFlat).reshaped(batch, k, maskH, maskW)
            let zero = 0.0.asMLXArray(dtype: encOutMasks.dtype)
            let boxes = maskToBoxCoordinate(encOutMasks .> zero, dtype: referencePointsUnact.dtype)
            referencePointsUnact = inverseSigmoid(boxes)
        }
        probe?.capture("reference_points_unact", tensor: referencePointsUnact)

        let decoded = decoder.forward(
            inputsEmbeds: target,
            encoderHiddenStates: sourceFlat,
            referencePointsUnact: referencePointsUnact,
            spatialShapes: spatialShapes,
            spatialShapesList: spatialShapesList,
            levelStartIndex: levelStartIndex,
            decoderNorm: decoderNorm,
            decoderOrderHead: decoderOrderHead,
            decoderGlobalPointer: decoderGlobalPointer,
            classHead: encScoreHead,
            bboxHead: encBBoxHead,
            probe: probe
        )

        try checkedEval(decoded.logits, decoded.boxes, decoded.orderLogits)

        return PPDocLayoutV3Model.RawOutputs(
            logits: decoded.logits,
            predBoxes: decoded.boxes,
            orderLogits: decoded.orderLogits,
            encoderTopKIndices: topkInd,
            didFallbackToAllQueries: false
        )
    }

    private func stableTopKIndices(maxScores: MLXArray, k: Int) -> MLXArray {
        let batch = maxScores.dim(0)
        let length = maxScores.dim(1)
        if k <= 0 || length <= 0 { return MLXArray.zeros([batch, 0], dtype: .int32) }

        let scores = maxScores.asType(.float32).asArray(Float.self)
        let kk = min(k, length)

        var selected = [Int32](repeating: 0, count: batch * kk)
        for b in 0 ..< batch {
            let rowOffset = b * length
            var items: [(score: Float, index: Int32)] = []
            items.reserveCapacity(length)
            for i in 0 ..< length {
                items.append((score: scores[rowOffset + i], index: Int32(i)))
            }
            items.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.index < b.index
            }
            for i in 0 ..< kk {
                selected[b * kk + i] = items[i].index
            }
        }
        return MLXArray(selected).reshaped(batch, kk)
    }

    private func maskToBoxCoordinate(_ mask: MLXArray, dtype: DType) -> MLXArray {
        // mask shape [B, Q, H, W] (bool)
        let batch = mask.dim(0)
        let numQueries = mask.dim(1)
        let height = mask.dim(2)
        let width = mask.dim(3)

        let gridY = arange(0, height, dtype: dtype)
        let gridX = arange(0, width, dtype: dtype)
        let grids = meshGrid([gridY, gridX], indexing: .ij)
        let yy = grids[0]
        let xx = grids[1]

        let maskFloat = mask.asType(dtype)
        let xMasked = xx * maskFloat
        let yMasked = yy * maskFloat

        let flat = height * width

        let xMax = xMasked.reshaped(batch, numQueries, flat).max(axis: -1) + 1
        let yMax = yMasked.reshaped(batch, numQueries, flat).max(axis: -1) + 1

        let maxFloat = finfoMax(dtype: dtype)
        let xForMin = which(mask, xMasked, maxFloat)
        let yForMin = which(mask, yMasked, maxFloat)

        let xMin = xForMin.reshaped(batch, numQueries, flat).min(axis: -1)
        let yMin = yForMin.reshaped(batch, numQueries, flat).min(axis: -1)

        var bbox = stacked([xMin, yMin, xMax, yMax], axis: -1) // [B, Q, 4] in xyxy

        let nonEmpty = mask.any(axes: [-2, -1]).expandedDimensions(axis: -1).asType(dtype)
        bbox = bbox * nonEmpty

        let norm = MLXArray([Float(width), Float(height), Float(width), Float(height)]).asType(dtype)
        let normalized = bbox / norm

        let x1 = normalized[0..., 0..., 0]
        let y1 = normalized[0..., 0..., 1]
        let x2 = normalized[0..., 0..., 2]
        let y2 = normalized[0..., 0..., 3]

        let cx = (x1 + x2) / 2
        let cy = (y1 + y2) / 2
        let w = x2 - x1
        let h = y2 - y1

        return stacked([cx, cy, w, h], axis: -1)
    }

    private func inverseSigmoid(_ x: MLXArray, eps: Float = 1e-5) -> MLXArray {
        let x = clip(x, min: 0, max: 1)
        let x1 = clip(x, min: eps)
        let x2 = clip(1 - x, min: eps)
        return log(x1 / x2)
    }

    private func finfoMax(dtype: DType) -> MLXArray {
        let value = switch dtype {
        case .float16:
            Float(Float16.greatestFiniteMagnitude)
        default:
            Float.greatestFiniteMagnitude
        }
        return value.asMLXArray(dtype: dtype)
    }

    private func generateAnchors(spatialShapes: [(h: Int, w: Int)], dtype: DType) -> (anchors: MLXArray, validMask: MLXArray) {
        let gridSize: Float = 0.05
        var anchorsByLevel: [MLXArray] = []
        anchorsByLevel.reserveCapacity(spatialShapes.count)

        for (level, shape) in spatialShapes.enumerated() {
            let height = shape.h
            let width = shape.w

            let gridY = arange(0, height, dtype: dtype)
            let gridX = arange(0, width, dtype: dtype)
            let grids = meshGrid([gridY, gridX], indexing: .ij)
            let yy = grids[0]
            let xx = grids[1]

            let wScalar = Float(width).asMLXArray(dtype: dtype)
            let hScalar = Float(height).asMLXArray(dtype: dtype)
            let xxNorm = (xx + 0.5) / wScalar
            let yyNorm = (yy + 0.5) / hScalar
            let gridXY = stacked([xxNorm, yyNorm], axis: -1)

            let scale = (gridSize * pow(2.0, Float(level))).asMLXArray(dtype: dtype)
            let wh = MLXArray.ones(like: gridXY) * scale

            let anchor = concatenated([gridXY, wh], axis: -1).reshaped(1, height * width, 4)
            anchorsByLevel.append(anchor)
        }

        let anchors = concatenated(anchorsByLevel, axis: 1)
        let eps: Float = 1e-2
        // PyTorch MPS compares fp16 anchors against fp32 eps; match that behavior to keep top-k ordering stable.
        let validityDType: DType = (dtype == .float16) ? .float32 : dtype
        let anchorsValidity = anchors.asType(validityDType)
        let epsArray = eps.asMLXArray(dtype: validityDType)
        let oneMinus = (1.0 - eps).asMLXArray(dtype: validityDType)
        let gt = anchorsValidity .> epsArray
        let lt = anchorsValidity .< oneMinus
        let valid = logicalAnd(gt, lt).all(axes: [-1], keepDims: true)

        let anchorsLogit = log(anchors / (1 - anchors))
        let maxFloat = finfoMax(dtype: dtype)
        let anchorsMasked = which(valid, anchorsLogit, maxFloat)
        return (anchorsMasked, valid)
    }

    private func postProcessObjectDetection(
        logits: MLXArray,
        boxes: MLXArray,
        orderLogits: MLXArray,
        scoreThreshold: Float
    ) -> PPDocLayoutV3Postprocess.RawDetections {
        let numQueries = boxes.dim(1)
        let numClasses = logits.dim(2)

        let logitsArray = logits.asArray(Float.self)
        let boxesArray = boxes.asArray(Float.self)
        let orderLogitsArray = orderLogits.asArray(Float.self)

        let orderSeqFull = computeOrderSeq(orderLogitsArray, numQueries: numQueries)

        // Convert boxes from cxcywh to xyxy (normalized 0..1)
        var boxesXYXY = Array(repeating: (x1: Float(0), y1: Float(0), x2: Float(0), y2: Float(0)), count: numQueries)
        for q in 0 ..< numQueries {
            let base = q * 4
            let cx = boxesArray[base + 0]
            let cy = boxesArray[base + 1]
            let w = boxesArray[base + 2]
            let h = boxesArray[base + 3]
            let x1 = cx - 0.5 * w
            let y1 = cy - 0.5 * h
            let x2 = cx + 0.5 * w
            let y2 = cy + 0.5 * h
            boxesXYXY[q] = (x1: x1, y1: y1, x2: x2, y2: y2)
        }

        // Compute sigmoid(scores) and take top-K over flattened (query * class).
        let totalScores = numQueries * numClasses
        var scored: [(score: Float, flatIndex: Int)] = []
        scored.reserveCapacity(totalScores)

        for flat in 0 ..< totalScores {
            let score = sigmoidFloat(logitsArray[flat])
            scored.append((score: score, flatIndex: flat))
        }
        scored.sort { $0.score > $1.score }

        let top = scored.prefix(numQueries)

        // swiftlint:disable:next large_tuple
        var kept: [(score: Float, label: Int, bbox: OCRNormalizedBBox, order: Int)] = []
        kept.reserveCapacity(numQueries)

        for item in top {
            let score = item.score
            if score < scoreThreshold { continue }

            let queryIndex = item.flatIndex / numClasses
            let label = item.flatIndex % numClasses
            let order = orderSeqFull[queryIndex]

            let b = boxesXYXY[queryIndex]
            let bbox = toNormalizedBBox(x1: b.x1, y1: b.y1, x2: b.x2, y2: b.y2)
            guard bbox.x1 < bbox.x2, bbox.y1 < bbox.y2 else { continue }

            kept.append((score: score, label: label, bbox: bbox, order: order))
        }

        kept.sort { a, b in
            if a.order != b.order { return a.order < b.order }
            if a.bbox.y1 != b.bbox.y1 { return a.bbox.y1 < b.bbox.y1 }
            return a.bbox.x1 < b.bbox.x1
        }

        return PPDocLayoutV3Postprocess.RawDetections(
            scores: kept.map(\.score),
            labels: kept.map(\.label),
            boxes: kept.map(\.bbox),
            orderSeq: kept.map(\.order),
            polygons: nil
        )
    }

    private func computeOrderSeq(_ orderLogits: [Float], numQueries: Int) -> [Int] {
        // order_logits shape is [1, num_queries, num_queries] flattened.
        let n = numQueries
        var scores = Array(repeating: Float(0), count: n * n)
        for i in 0 ..< min(orderLogits.count, n * n) {
            scores[i] = sigmoidFloat(orderLogits[i])
        }

        var votes = Array(repeating: Float(0), count: n)
        for j in 0 ..< n {
            var sum: Float = 0
            // upper triangle contribution: sum_{i<j} score[i,j]
            for i in 0 ..< j {
                sum += scores[i * n + j]
            }
            // lower triangle contribution: sum_{i>j} (1 - score[j,i])
            if j + 1 < n {
                for i in (j + 1) ..< n {
                    sum += (1 - scores[j * n + i])
                }
            }
            votes[j] = sum
        }

        var pointers = Array(0 ..< n)
        pointers.sort { votes[$0] < votes[$1] }

        var orderSeq = Array(repeating: 0, count: n)
        for (rank, idx) in pointers.enumerated() {
            orderSeq[idx] = rank + 1 // 1-based order
        }
        return orderSeq
    }
}

// MARK: - Utilities

private func sigmoidFloat(_ x: Float) -> Float {
    1 / (1 + exp(-x))
}

private func toNormalizedBBox(x1: Float, y1: Float, x2: Float, y2: Float) -> OCRNormalizedBBox {
    func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }

    let x1 = clamp01(x1)
    let y1 = clamp01(y1)
    let x2 = clamp01(x2)
    let y2 = clamp01(y2)

    let nx1 = Int((x1 * 1000).rounded(.down))
    let ny1 = Int((y1 * 1000).rounded(.down))
    let nx2 = Int((x2 * 1000).rounded(.up))
    let ny2 = Int((y2 * 1000).rounded(.up))

    return OCRNormalizedBBox(
        x1: max(0, min(1000, nx1)),
        y1: max(0, min(1000, ny1)),
        x2: max(0, min(1000, nx2)),
        y2: max(0, min(1000, ny2))
    )
}

// MARK: - Lightweight building blocks

final class PPMLPPredictionHead: Module, UnaryLayer {
    @ModuleInfo(key: "layers") var layers: [Linear]

    init(inputDim: Int, hiddenDim: Int, outputDim: Int, numLayers: Int) {
        let numLayers = max(numLayers, 1)
        var linears: [Linear] = []
        linears.reserveCapacity(numLayers)
        for i in 0 ..< numLayers {
            let inDim = (i == 0) ? inputDim : hiddenDim
            let outDim = (i == numLayers - 1) ? outputDim : hiddenDim
            linears.append(Linear(inDim, outDim))
        }
        _layers.wrappedValue = linears
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        for i in layers.indices {
            x = layers[i](x)
            if i < layers.count - 1 {
                x = relu(x)
            }
        }
        return x
    }
}

final class PPGlobalPointer: Module, UnaryLayer {
    @ModuleInfo(key: "dense") var dense: Linear

    private let headSize: Int

    init(dModel: Int, headSize: Int) {
        self.headSize = max(headSize, 1)
        _dense.wrappedValue = Linear(dModel, self.headSize * 2)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let batch = x.dim(0)
        let seq = x.dim(1)

        let proj = dense(x).reshaped(batch, seq, 2, headSize)
        let parts = split(proj, parts: 2, axis: 2)
        let queries = parts[0].squeezed(axis: 2)
        let keys = parts[1].squeezed(axis: 2)

        let logits = matmul(queries, transposed(keys, axes: [0, 2, 1])) / sqrt(Float(headSize))

        let mask = MLXArray.tri(seq, m: seq, k: 0, dtype: .bool).reshaped(1, seq, seq)
        let fill = (-1e4).asMLXArray(dtype: logits.dtype)
        return which(mask, fill, logits)
    }
}

// MARK: - HGNetV2 backbone (channels-last)

final class PPDocLayoutV3ConvEncoderCore: Module {
    @ModuleInfo(key: "model") var model: HGNetV2BackboneCore

    init(model: HGNetV2BackboneCore = HGNetV2BackboneCore()) {
        _model.wrappedValue = model
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> [MLXArray] {
        model(x)
    }
}

final class HGNetV2BackboneCore: Module {
    @ModuleInfo(key: "embedder") var embedder: HGNetV2EmbeddingsCore
    @ModuleInfo(key: "encoder") var encoder: HGNetV2EncoderCore

    override init() {
        _embedder.wrappedValue = HGNetV2EmbeddingsCore()
        _encoder.wrappedValue = HGNetV2EncoderCore()
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> [MLXArray] {
        var hidden = embedder(x)
        var featureMaps: [MLXArray] = []
        featureMaps.reserveCapacity(encoder.stages.count)
        for stage in encoder.stages {
            hidden = stage(hidden)
            featureMaps.append(hidden)
        }
        return featureMaps
    }
}

final class HGNetV2EmbeddingsCore: Module, UnaryLayer {
    @ModuleInfo(key: "stem1") var stem1: HGNetV2ConvLayerCore
    @ModuleInfo(key: "stem2a") var stem2a: HGNetV2ConvLayerCore
    @ModuleInfo(key: "stem2b") var stem2b: HGNetV2ConvLayerCore
    @ModuleInfo(key: "stem3") var stem3: HGNetV2ConvLayerCore
    @ModuleInfo(key: "stem4") var stem4: HGNetV2ConvLayerCore

    private let pool = MaxPool2d(kernelSize: 2, stride: 1)

    override init() {
        _stem1.wrappedValue = HGNetV2ConvLayerCore(inChannels: 3, outChannels: 32, kernel: 3, stride: 2, groups: 1, activation: .relu)
        _stem2a.wrappedValue = HGNetV2ConvLayerCore(inChannels: 32, outChannels: 16, kernel: 2, stride: 1, groups: 1, activation: .relu)
        _stem2b.wrappedValue = HGNetV2ConvLayerCore(inChannels: 16, outChannels: 32, kernel: 2, stride: 1, groups: 1, activation: .relu)
        _stem3.wrappedValue = HGNetV2ConvLayerCore(inChannels: 64, outChannels: 32, kernel: 3, stride: 2, groups: 1, activation: .relu)
        _stem4.wrappedValue = HGNetV2ConvLayerCore(inChannels: 32, outChannels: 48, kernel: 1, stride: 1, groups: 1, activation: .relu)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var embedding = stem1(x)
        embedding = padRightBottom1(embedding)

        var stem = stem2a(embedding)
        stem = padRightBottom1(stem)
        stem = stem2b(stem)

        let pooled = pool(embedding)
        embedding = concatenated([pooled, stem], axis: -1)
        embedding = stem3(embedding)
        embedding = stem4(embedding)
        return embedding
    }

    private func padRightBottom1(_ x: MLXArray) -> MLXArray {
        padded(x, widths: [0, [0, 1], [0, 1], 0], mode: .constant, value: MLXArray(0, dtype: x.dtype))
    }
}

final class HGNetV2EncoderCore: Module {
    @ModuleInfo(key: "stages") var stages: [HGNetV2StageCore]

    override init() {
        _stages.wrappedValue = [
            HGNetV2StageCore(
                stageIndex: 0,
                inChannels: 48,
                midChannels: 48,
                outChannels: 128,
                numBlocks: 1,
                numLayers: 6,
                downsample: false,
                lightBlock: false,
                kernelSize: 3
            ),
            HGNetV2StageCore(
                stageIndex: 1,
                inChannels: 128,
                midChannels: 96,
                outChannels: 512,
                numBlocks: 1,
                numLayers: 6,
                downsample: true,
                lightBlock: false,
                kernelSize: 3
            ),
            HGNetV2StageCore(
                stageIndex: 2,
                inChannels: 512,
                midChannels: 192,
                outChannels: 1024,
                numBlocks: 3,
                numLayers: 6,
                downsample: true,
                lightBlock: true,
                kernelSize: 5
            ),
            HGNetV2StageCore(
                stageIndex: 3,
                inChannels: 1024,
                midChannels: 384,
                outChannels: 2048,
                numBlocks: 1,
                numLayers: 6,
                downsample: true,
                lightBlock: true,
                kernelSize: 5
            ),
        ]
        super.init()
    }
}

final class HGNetV2StageCore: Module, UnaryLayer {
    @ModuleInfo(key: "downsample") var downsampleLayer: Module
    @ModuleInfo(key: "blocks") var blocks: [HGNetV2BasicLayerCore]

    init(
        stageIndex _: Int,
        inChannels: Int,
        midChannels: Int,
        outChannels: Int,
        numBlocks: Int,
        numLayers: Int,
        downsample: Bool,
        lightBlock: Bool,
        kernelSize: Int
    ) {
        if downsample {
            _downsampleLayer.wrappedValue = HGNetV2ConvLayerCore(inChannels: inChannels, outChannels: inChannels, kernel: 3, stride: 2, groups: inChannels, activation: nil)
        } else {
            _downsampleLayer.wrappedValue = Identity()
        }

        var stageBlocks: [HGNetV2BasicLayerCore] = []
        stageBlocks.reserveCapacity(numBlocks)
        for i in 0 ..< max(numBlocks, 1) {
            stageBlocks.append(
                HGNetV2BasicLayerCore(
                    inChannels: i == 0 ? inChannels : outChannels,
                    midChannels: midChannels,
                    outChannels: outChannels,
                    numLayers: numLayers,
                    residual: i != 0,
                    lightBlock: lightBlock,
                    kernelSize: kernelSize
                )
            )
        }
        _blocks.wrappedValue = stageBlocks
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        guard let downsampleLayer = downsampleLayer as? UnaryLayer else {
            fatalError("downsample layer does not conform to UnaryLayer")
        }
        var x = downsampleLayer(x)
        for block in blocks {
            x = block(x)
        }
        return x
    }
}

final class HGNetV2BasicLayerCore: Module, UnaryLayer {
    @ModuleInfo(key: "layers") var layers: [Module]
    @ModuleInfo(key: "aggregation") var aggregation: [HGNetV2ConvLayerCore]

    private let residual: Bool

    init(
        inChannels: Int,
        midChannels: Int,
        outChannels: Int,
        numLayers: Int,
        residual: Bool,
        lightBlock: Bool,
        kernelSize: Int
    ) {
        self.residual = residual

        var layerModules: [Module] = []
        layerModules.reserveCapacity(max(numLayers, 1))
        for i in 0 ..< max(numLayers, 1) {
            let tempIn = (i == 0) ? inChannels : midChannels
            if lightBlock {
                layerModules.append(HGNetV2ConvLayerLightCore(inChannels: tempIn, outChannels: midChannels, kernel: kernelSize))
            } else {
                layerModules.append(HGNetV2ConvLayerCore(inChannels: tempIn, outChannels: midChannels, kernel: kernelSize, stride: 1, groups: 1, activation: .relu))
            }
        }
        _layers.wrappedValue = layerModules

        let totalChannels = inChannels + max(numLayers, 1) * midChannels
        _aggregation.wrappedValue = [
            HGNetV2ConvLayerCore(inChannels: totalChannels, outChannels: outChannels / 2, kernel: 1, stride: 1, groups: 1, activation: .relu),
            HGNetV2ConvLayerCore(inChannels: outChannels / 2, outChannels: outChannels, kernel: 1, stride: 1, groups: 1, activation: .relu),
        ]

        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let identity = x
        var outputs: [MLXArray] = []
        outputs.reserveCapacity(layers.count + 1)
        outputs.append(x)

        var hidden = x
        for layer in layers {
            guard let layer = layer as? UnaryLayer else {
                fatalError("HGNetV2BasicLayerCore.layers contains non-UnaryLayer module: \(type(of: layer))")
            }
            hidden = layer(hidden)
            outputs.append(hidden)
        }

        hidden = concatenated(outputs, axis: -1)
        hidden = aggregation[0](hidden)
        hidden = aggregation[1](hidden)
        if residual {
            hidden = hidden + identity
        }
        return hidden
    }
}

final class HGNetV2ConvLayerLightCore: Module, UnaryLayer {
    @ModuleInfo(key: "conv1") var conv1: HGNetV2ConvLayerCore
    @ModuleInfo(key: "conv2") var conv2: HGNetV2ConvLayerCore

    init(inChannels: Int, outChannels: Int, kernel: Int) {
        _conv1.wrappedValue = HGNetV2ConvLayerCore(inChannels: inChannels, outChannels: outChannels, kernel: 1, stride: 1, groups: 1, activation: nil)
        _conv2.wrappedValue = HGNetV2ConvLayerCore(inChannels: outChannels, outChannels: outChannels, kernel: kernel, stride: 1, groups: outChannels, activation: .relu)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        conv2(conv1(x))
    }
}

enum HGNetActivation: Sendable {
    case relu
}

final class HGNetV2ConvLayerCore: Module, UnaryLayer {
    @ModuleInfo(key: "convolution") var convolution: Conv2d
    @ModuleInfo(key: "normalization") var normalization: BatchNorm

    private let activation: HGNetActivation?

    init(
        inChannels: Int,
        outChannels: Int,
        kernel: Int,
        stride: Int,
        groups: Int,
        activation: HGNetActivation?
    ) {
        self.activation = activation
        let padding = (kernel - 1) / 2
        _convolution.wrappedValue = Conv2d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: .init(kernel),
            stride: .init(stride),
            padding: .init(padding),
            groups: groups,
            bias: false
        )
        _normalization.wrappedValue = BatchNorm(featureCount: outChannels)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var y = normalization(convolution(x))
        if activation == .relu {
            y = relu(y)
        }
        return y
    }
}
