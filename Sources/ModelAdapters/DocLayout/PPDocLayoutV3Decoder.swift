import Foundation
import MLX
import MLXNN

private func inverseSigmoid(_ x: MLXArray, eps: Float = 1e-5) -> MLXArray {
    let x = clip(x, min: 0, max: 1)
    let x1 = clip(x, min: eps)
    let x2 = clip(1 - x, min: eps)
    return log(x1 / x2)
}

private func gridSampleBilinearNHWC(_ input: MLXArray, grid: MLXArray) -> MLXArray {
    let n = input.dim(0)
    let height = input.dim(1)
    let width = input.dim(2)
    let channels = input.dim(3)

    let outH = grid.dim(1)
    let outW = grid.dim(2)
    let outHW = outH * outW

    let computeDType: DType = (input.dtype == .float16) ? .float32 : input.dtype
    let gx = grid[0..., 0..., 0..., 0].asType(computeDType)
    let gy = grid[0..., 0..., 0..., 1].asType(computeDType)

    let wScalar = Float(width).asMLXArray(dtype: computeDType)
    let hScalar = Float(height).asMLXArray(dtype: computeDType)

    // align_corners=false mapping:
    // x = ((gx + 1) * W - 1) / 2
    // y = ((gy + 1) * H - 1) / 2
    let ix = ((gx + 1) * wScalar - 1) / 2
    let iy = ((gy + 1) * hScalar - 1) / 2

    let x0 = floor(ix)
    let y0 = floor(iy)
    let x1 = x0 + 1
    let y1 = y0 + 1

    let wx = ix - x0
    let wy = iy - y0

    let x0Valid = logicalAnd(x0 .>= 0, x0 .< wScalar)
    let x1Valid = logicalAnd(x1 .>= 0, x1 .< wScalar)
    let y0Valid = logicalAnd(y0 .>= 0, y0 .< hScalar)
    let y1Valid = logicalAnd(y1 .>= 0, y1 .< hScalar)

    let maxX = Float(max(width - 1, 0)).asMLXArray(dtype: computeDType)
    let maxY = Float(max(height - 1, 0)).asMLXArray(dtype: computeDType)

    let x0c = clip(x0, min: 0, max: maxX).asType(.int32)
    let x1c = clip(x1, min: 0, max: maxX).asType(.int32)
    let y0c = clip(y0, min: 0, max: maxY).asType(.int32)
    let y1c = clip(y1, min: 0, max: maxY).asType(.int32)

    let wInt = Int32(width).asMLXArray(dtype: .int32)
    let idx00 = (y0c * wInt + x0c).reshaped(n, outHW, 1)
    let idx01 = (y0c * wInt + x1c).reshaped(n, outHW, 1)
    let idx10 = (y1c * wInt + x0c).reshaped(n, outHW, 1)
    let idx11 = (y1c * wInt + x1c).reshaped(n, outHW, 1)

    let flat = input.asType(computeDType).reshaped(n, height * width, channels)
    let idxBroadcast00 = broadcast(idx00, to: [n, outHW, channels])
    let idxBroadcast01 = broadcast(idx01, to: [n, outHW, channels])
    let idxBroadcast10 = broadcast(idx10, to: [n, outHW, channels])
    let idxBroadcast11 = broadcast(idx11, to: [n, outHW, channels])

    let v00 = takeAlong(flat, idxBroadcast00, axis: 1)
    let v01 = takeAlong(flat, idxBroadcast01, axis: 1)
    let v10 = takeAlong(flat, idxBroadcast10, axis: 1)
    let v11 = takeAlong(flat, idxBroadcast11, axis: 1)

    let wxR = wx.reshaped(n, outHW, 1)
    let wyR = wy.reshaped(n, outHW, 1)
    let one = 1.0.asMLXArray(dtype: wxR.dtype)

    let m00 = logicalAnd(x0Valid, y0Valid).reshaped(n, outHW, 1).asType(wxR.dtype)
    let m01 = logicalAnd(x1Valid, y0Valid).reshaped(n, outHW, 1).asType(wxR.dtype)
    let m10 = logicalAnd(x0Valid, y1Valid).reshaped(n, outHW, 1).asType(wxR.dtype)
    let m11 = logicalAnd(x1Valid, y1Valid).reshaped(n, outHW, 1).asType(wxR.dtype)

    let w00 = (one - wxR) * (one - wyR) * m00
    let w01 = wxR * (one - wyR) * m01
    let w10 = (one - wxR) * wyR * m10
    let w11 = wxR * wyR * m11

    let out = (w00 * v00) + (w01 * v01) + (w10 * v10) + (w11 * v11)
    return out.asType(input.dtype).reshaped(n, outH, outW, channels)
}

private func multiScaleDeformableAttentionCore(
    value: MLXArray,
    spatialShapesList: [(height: Int, width: Int)],
    samplingLocations: MLXArray,
    attentionWeights: MLXArray,
    probe: PPDocLayoutV3IntermediateProbe? = nil,
    probePrefix: String? = nil
) -> MLXArray {
    let batch = value.dim(0)
    let sequenceLength = value.dim(1)
    let numHeads = value.dim(2)
    let headDim = value.dim(3)

    let numQueries = samplingLocations.dim(1)
    let numLevels = samplingLocations.dim(3)
    let numPoints = samplingLocations.dim(4)

    precondition(numLevels == spatialShapesList.count, "spatialShapesList count must match numLevels")

    // Split value by level and sample each level with grid_sample.
    var sampledByLevel: [MLXArray] = []
    sampledByLevel.reserveCapacity(spatialShapesList.count)

    var start = 0
    let samplingGrids = samplingLocations * 2 - 1

    for (levelId, shape) in spatialShapesList.enumerated() {
        let levelLen = shape.height * shape.width
        precondition(start + levelLen <= sequenceLength, "value does not contain enough elements for spatialShapesList")

        let valueLevel = value[0..., start ..< (start + levelLen), 0..., 0...]
            .reshaped(batch, shape.height, shape.width, numHeads, headDim)
            .transposed(0, 3, 1, 2, 4)
            .reshaped(batch * numHeads, shape.height, shape.width, headDim)

        let gridLevel = samplingGrids[0..., 0..., 0..., levelId, 0..., 0...]
            .transposed(0, 2, 1, 3, 4)
            .reshaped(batch * numHeads, numQueries, numPoints, 2)

        let sampled = gridSampleBilinearNHWC(valueLevel, grid: gridLevel)

        if let probePrefix {
            probe?.capture("\(probePrefix).value.level\(levelId)", tensor: valueLevel)
            probe?.capture("\(probePrefix).grid.level\(levelId)", tensor: gridLevel)
            probe?.capture("\(probePrefix).sampled.level\(levelId)", tensor: sampled)
        }
        sampledByLevel.append(sampled)

        start += levelLen
    }

    let sampledStack = stacked(sampledByLevel, axis: 2) // [B*H, Q, L, P, D]
    let sampledFlat = sampledStack.reshaped(batch * numHeads, numQueries, numLevels * numPoints, headDim)

    let weightsFlat = attentionWeights
        .transposed(0, 2, 1, 3, 4)
        .reshaped(batch * numHeads, numQueries, numLevels * numPoints)

    let accumDType: DType = (value.dtype == .float16) ? .float32 : value.dtype
    let sampledAccum = sampledFlat.asType(accumDType)
    let weightsAccum = weightsFlat.asType(accumDType)

    let weighted = sampledAccum * weightsAccum.expandedDimensions(axis: -1)
    let summed = weighted.sum(axis: 2) // [B*H, Q, D]

    let merged = summed
        .reshaped(batch, numHeads, numQueries, headDim)
        .transposed(0, 2, 1, 3)
        .reshaped(batch, numQueries, numHeads * headDim)

    return merged.asType(value.dtype)
}

final class PPDocLayoutV3MultiscaleDeformableAttentionCore: Module {
    @ModuleInfo(key: "sampling_offsets") var samplingOffsets: Linear
    @ModuleInfo(key: "attention_weights") var attentionWeights: Linear
    @ModuleInfo(key: "value_proj") var valueProj: Linear
    @ModuleInfo(key: "output_proj") var outputProj: Linear

    private let dModel: Int
    private let nLevels: Int
    private let nHeads: Int
    private let nPoints: Int

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        dModel = modelConfig.dModel
        nLevels = modelConfig.numFeatureLevels
        nHeads = modelConfig.decoderAttentionHeads
        nPoints = modelConfig.decoderNPoints

        _samplingOffsets.wrappedValue = Linear(dModel, nHeads * nLevels * nPoints * 2, bias: true)
        _attentionWeights.wrappedValue = Linear(dModel, nHeads * nLevels * nPoints, bias: true)
        _valueProj.wrappedValue = Linear(dModel, dModel, bias: true)
        _outputProj.wrappedValue = Linear(dModel, dModel, bias: true)
        super.init()
    }

    func forward(
        hiddenStates: MLXArray,
        encoderHiddenStates: MLXArray,
        positionEmbeddings: MLXArray? = nil,
        referencePoints: MLXArray,
        spatialShapes: MLXArray,
        spatialShapesList: [(height: Int, width: Int)],
        levelStartIndex _: MLXArray? = nil,
        attentionMask: MLXArray? = nil,
        probe: PPDocLayoutV3IntermediateProbe? = nil,
        probePrefix: String? = nil
    ) -> MLXArray {
        var hiddenStates = hiddenStates
        if let positionEmbeddings {
            hiddenStates = hiddenStates + positionEmbeddings
        }

        let batch = hiddenStates.dim(0)
        let numQueries = hiddenStates.dim(1)
        let sequenceLength = encoderHiddenStates.dim(1)

        precondition(
            spatialShapesList.map { $0.height * $0.width }.reduce(0, +) == sequenceLength,
            "spatialShapesList must sum to sequenceLength"
        )

        var value = valueProj(encoderHiddenStates)
        if let attentionMask {
            value = value * attentionMask.asType(value.dtype).expandedDimensions(axis: -1)
        }

        let headDim = max(dModel / max(nHeads, 1), 1)
        value = value.reshaped(batch, sequenceLength, nHeads, headDim)

        let samplingOffsetsTensor = samplingOffsets(hiddenStates)
            .reshaped(batch, numQueries, nHeads, nLevels, nPoints, 2)

        var weights = attentionWeights(hiddenStates)
            .reshaped(batch, numQueries, nHeads, nLevels * nPoints)
        weights = softmax(weights, axis: -1)
            .reshaped(batch, numQueries, nHeads, nLevels, nPoints)

        let numCoordinates = referencePoints.dim(-1)
        let samplingLocations: MLXArray
        if numCoordinates == 2 {
            let widths = spatialShapes[0..., 1].asType(hiddenStates.dtype)
            let heights = spatialShapes[0..., 0].asType(hiddenStates.dtype)
            let offsetNormalizer = stacked([widths, heights], axis: -1) // [L, 2] (w, h)
            samplingLocations =
                referencePoints[0..., 0..., .newAxis, 0..., .newAxis, 0...]
                    + samplingOffsetsTensor / offsetNormalizer[.newAxis, .newAxis, .newAxis, 0..., .newAxis, 0...]
        } else if numCoordinates == 4 {
            let base = referencePoints[0..., 0..., .newAxis, 0..., .newAxis, ..<2]
            let scale = referencePoints[0..., 0..., .newAxis, 0..., .newAxis, 2...] * 0.5
            samplingLocations = base + (samplingOffsetsTensor / Float(nPoints)) * scale
        } else {
            fatalError("referencePoints last dim must be 2 or 4, got \(numCoordinates)")
        }

        if let probePrefix {
            probe?.capture("\(probePrefix).sampling_offsets", tensor: samplingOffsetsTensor)
            probe?.capture("\(probePrefix).attention_weights", tensor: weights)
            probe?.capture("\(probePrefix).sampling_locations", tensor: samplingLocations)
        }

        let attended = multiScaleDeformableAttentionCore(
            value: value,
            spatialShapesList: spatialShapesList,
            samplingLocations: samplingLocations,
            attentionWeights: weights,
            probe: probe,
            probePrefix: probePrefix
        )
        return outputProj(attended)
    }
}

final class PPDocLayoutV3DecoderLayerCore: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: PPDocLayoutV3SelfAttentionCore
    @ModuleInfo(key: "self_attn_layer_norm") var selfAttnLayerNorm: LayerNorm

    @ModuleInfo(key: "encoder_attn") var encoderAttn: PPDocLayoutV3MultiscaleDeformableAttentionCore
    @ModuleInfo(key: "encoder_attn_layer_norm") var encoderAttnLayerNorm: LayerNorm

    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm

    private let activation: PPDocLayoutV3Activation

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        let dModel = modelConfig.dModel
        _selfAttn.wrappedValue = PPDocLayoutV3SelfAttentionCore(hiddenSize: dModel, numHeads: modelConfig.decoderAttentionHeads)

        let lnEps = Float(modelConfig.layerNormEps ?? 1e-5)
        _selfAttnLayerNorm.wrappedValue = LayerNorm(dimensions: dModel, eps: lnEps)

        _encoderAttn.wrappedValue = PPDocLayoutV3MultiscaleDeformableAttentionCore(modelConfig: modelConfig)
        _encoderAttnLayerNorm.wrappedValue = LayerNorm(dimensions: dModel, eps: lnEps)

        _fc1.wrappedValue = Linear(dModel, modelConfig.decoderFFNDim, bias: true)
        _fc2.wrappedValue = Linear(modelConfig.decoderFFNDim, dModel, bias: true)
        _finalLayerNorm.wrappedValue = LayerNorm(dimensions: dModel, eps: lnEps)

        activation = PPDocLayoutV3Activation(modelConfig.decoderActivationFunction)
        super.init()
    }

    func forward(
        hiddenStates: MLXArray,
        objectQueriesPositionEmbeddings: MLXArray?,
        referencePoints: MLXArray,
        spatialShapes: MLXArray,
        spatialShapesList: [(height: Int, width: Int)],
        levelStartIndex: MLXArray,
        encoderHiddenStates: MLXArray,
        probe: PPDocLayoutV3IntermediateProbe? = nil,
        probePrefix: String? = nil
    ) -> MLXArray {
        var hiddenStates = hiddenStates

        var residual = hiddenStates
        let selfOut = selfAttn.forward(
            hiddenStates: hiddenStates,
            attentionMask: nil,
            positionEmbeddings: objectQueriesPositionEmbeddings
        )
        if let probePrefix {
            probe?.capture("\(probePrefix).self_attn.out", tensor: selfOut)
        }

        let selfSum = residual + selfOut
        if let probePrefix {
            if let weight = selfAttnLayerNorm.weight {
                probe?.capture("\(probePrefix).self_attn_layer_norm.weight", tensor: weight)
            }
            if let bias = selfAttnLayerNorm.bias {
                probe?.capture("\(probePrefix).self_attn_layer_norm.bias", tensor: bias)
            }

            let hiddenSize = selfSum.dim(2)
            let denom = Float(hiddenSize).asMLXArray(dtype: selfSum.dtype)

            let mean = selfSum.sum(axis: 2) / denom
            let meanExpanded = mean.expandedDimensions(axis: -1)
            let variance = ((selfSum - meanExpanded) * (selfSum - meanExpanded)).sum(axis: 2) / denom

            probe?.capture("\(probePrefix).self_attn_layer_norm.input_mean", tensor: meanExpanded)
            probe?.capture("\(probePrefix).self_attn_layer_norm.input_var", tensor: variance.expandedDimensions(axis: -1))
        }

        hiddenStates = selfAttnLayerNorm(selfSum)
        if let probePrefix {
            let captureTensor = hiddenStates + 0.0.asMLXArray(dtype: hiddenStates.dtype)
            probe?.capture("\(probePrefix).hidden_states.pre_cross", tensor: captureTensor)

            let hiddenSize = captureTensor.dim(2)
            let denom = Float(hiddenSize).asMLXArray(dtype: captureTensor.dtype)
            let mean = captureTensor.sum(axis: 2) / denom
            probe?.capture("\(probePrefix).hidden_states.pre_cross_mean", tensor: mean.expandedDimensions(axis: -1))
        }

        residual = hiddenStates
        let crossOut = encoderAttn.forward(
            hiddenStates: hiddenStates,
            encoderHiddenStates: encoderHiddenStates,
            positionEmbeddings: objectQueriesPositionEmbeddings,
            referencePoints: referencePoints,
            spatialShapes: spatialShapes,
            spatialShapesList: spatialShapesList,
            levelStartIndex: levelStartIndex,
            attentionMask: nil,
            probe: probe,
            probePrefix: probePrefix.map { "\($0).encoder_attn" }
        )
        if let probePrefix {
            probe?.capture("\(probePrefix).encoder_attn.out", tensor: crossOut)

            let hiddenSize = crossOut.dim(2)
            let denom = Float(hiddenSize).asMLXArray(dtype: crossOut.dtype)
            let mean = crossOut.sum(axis: 2) / denom
            probe?.capture("\(probePrefix).encoder_attn.out_mean", tensor: mean.expandedDimensions(axis: -1))
        }
        let crossSum = residual + crossOut
        if let probePrefix {
            let captureTensor = crossSum + 0.0.asMLXArray(dtype: crossSum.dtype)
            probe?.capture("\(probePrefix).encoder_attn_layer_norm.input", tensor: captureTensor)

            if let weight = encoderAttnLayerNorm.weight {
                probe?.capture("\(probePrefix).encoder_attn_layer_norm.weight", tensor: weight)
            }
            if let bias = encoderAttnLayerNorm.bias {
                probe?.capture("\(probePrefix).encoder_attn_layer_norm.bias", tensor: bias)
            }

            let hiddenSize = captureTensor.dim(2)
            let denom = Float(hiddenSize).asMLXArray(dtype: captureTensor.dtype)

            let mean = captureTensor.sum(axis: 2) / denom
            let meanExpanded = mean.expandedDimensions(axis: -1)
            let variance = ((captureTensor - meanExpanded) * (captureTensor - meanExpanded)).sum(axis: 2) / denom

            probe?.capture("\(probePrefix).encoder_attn_layer_norm.input_mean", tensor: meanExpanded)
            probe?.capture("\(probePrefix).encoder_attn_layer_norm.input_var", tensor: variance.expandedDimensions(axis: -1))
        }

        hiddenStates = encoderAttnLayerNorm(crossSum)
        if let probePrefix {
            let captureTensor = hiddenStates + 0.0.asMLXArray(dtype: hiddenStates.dtype)
            probe?.capture("\(probePrefix).hidden_states.post_cross", tensor: captureTensor)
        }

        residual = hiddenStates
        hiddenStates = fc2(activation(fc1(hiddenStates)))
        hiddenStates = residual + hiddenStates
        hiddenStates = finalLayerNorm(hiddenStates)

        return hiddenStates
    }
}

struct PPDocLayoutV3DecoderOutputs: @unchecked Sendable {
    var hiddenStates: MLXArray
    var referencePoints: MLXArray
}

final class PPDocLayoutV3DecoderCore: Module {
    @ModuleInfo(key: "layers") var layers: [PPDocLayoutV3DecoderLayerCore]
    @ModuleInfo(key: "query_pos_head") var queryPosHead: PPMLPPredictionHead

    private let numQueries: Int

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        numQueries = modelConfig.numQueries
        _layers.wrappedValue = (0 ..< max(modelConfig.decoderLayers, 1)).map { _ in PPDocLayoutV3DecoderLayerCore(modelConfig: modelConfig) }
        _queryPosHead.wrappedValue = PPMLPPredictionHead(
            inputDim: 4,
            hiddenDim: 2 * modelConfig.dModel,
            outputDim: modelConfig.dModel,
            numLayers: 2
        )
        super.init()
    }

    func forward(
        inputsEmbeds: MLXArray,
        encoderHiddenStates: MLXArray,
        referencePointsUnact: MLXArray,
        spatialShapes: MLXArray,
        spatialShapesList: [(height: Int, width: Int)],
        levelStartIndex: MLXArray,
        decoderNorm: LayerNorm,
        decoderOrderHead: [Linear],
        decoderGlobalPointer: PPGlobalPointer,
        classHead: Linear,
        bboxHead: PPMLPPredictionHead,
        probe: PPDocLayoutV3IntermediateProbe? = nil
    ) -> (logits: MLXArray, boxes: MLXArray, orderLogits: MLXArray) {
        var hiddenStates = inputsEmbeds
        var referencePoints = sigmoid(referencePointsUnact)

        var logits = MLXArray(0)
        var orderLogits = MLXArray(0)

        for idx in layers.indices {
            let referencePointsInput = referencePoints.expandedDimensions(axis: 2)
            let objectQueryPos = queryPosHead(referencePoints)

            let layerPrefix = "decoder.layers.\(idx)"
            probe?.capture("\(layerPrefix).reference_points.in", tensor: referencePoints)
            probe?.capture("\(layerPrefix).object_query_pos", tensor: objectQueryPos)
            probe?.capture("\(layerPrefix).hidden_states.in", tensor: hiddenStates)

            hiddenStates = layers[idx].forward(
                hiddenStates: hiddenStates,
                objectQueriesPositionEmbeddings: objectQueryPos,
                referencePoints: referencePointsInput,
                spatialShapes: spatialShapes,
                spatialShapesList: spatialShapesList,
                levelStartIndex: levelStartIndex,
                encoderHiddenStates: encoderHiddenStates,
                probe: probe,
                probePrefix: layerPrefix
            )

            probe?.capture("\(layerPrefix).hidden_states.out", tensor: hiddenStates + 0.0.asMLXArray(dtype: hiddenStates.dtype))

            let predictedCorners = bboxHead(hiddenStates)
            let newReferencePoints = sigmoid(predictedCorners + inverseSigmoid(referencePoints))
            referencePoints = newReferencePoints
            probe?.capture("\(layerPrefix).bbox.predicted_corners", tensor: predictedCorners)
            probe?.capture("\(layerPrefix).reference_points.out", tensor: referencePoints)

            let outQuery = decoderNorm(hiddenStates)
            logits = classHead(outQuery)
            probe?.capture("\(layerPrefix).logits", tensor: logits)

            let validQuery = outQuery // no denoising during inference
            let orderHidden = decoderOrderHead[idx](validQuery)
            orderLogits = decoderGlobalPointer(orderHidden)
        }

        return (logits: logits, boxes: referencePoints, orderLogits: orderLogits)
    }
}
