import Foundation
import MLX
import MLXNN

enum PPDocLayoutV3Activation: Sendable {
    case identity
    case relu
    case gelu
    case silu

    init(_ name: String?) {
        switch name?.lowercased() {
        case "relu": self = .relu
        case "gelu": self = .gelu
        case "silu": self = .silu
        default: self = .identity
        }
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        switch self {
        case .identity: x
        case .relu: MLXNN.relu(x)
        case .gelu: MLXNN.gelu(x)
        case .silu: MLXNN.silu(x)
        }
    }
}

final class PPDocLayoutV3SelfAttentionCore: Module {
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    private let numHeads: Int
    private let headDim: Int
    private let scale: Float

    init(hiddenSize: Int, numHeads: Int) {
        let numHeads = max(numHeads, 1)
        let headDim = max(hiddenSize / numHeads, 1)
        self.numHeads = numHeads
        self.headDim = headDim
        scale = 1 / sqrt(Float(headDim))

        _kProj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: true)
        _vProj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: true)
        _qProj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: true)
        _outProj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: true)
        super.init()
    }

    func forward(
        hiddenStates: MLXArray,
        attentionMask: MLXArray? = nil,
        positionEmbeddings: MLXArray? = nil
    ) -> MLXArray {
        let queryKeyInput = if let positionEmbeddings { hiddenStates + positionEmbeddings } else { hiddenStates }
        let batch = queryKeyInput.dim(0)
        let seq = queryKeyInput.dim(1)
        let hiddenSize = queryKeyInput.dim(2)

        let q = qProj(queryKeyInput)
            .reshaped(batch, seq, numHeads, headDim)
            .transposed(0, 2, 1, 3)
        let k = kProj(queryKeyInput)
            .reshaped(batch, seq, numHeads, headDim)
            .transposed(0, 2, 1, 3)
        let v = vProj(hiddenStates)
            .reshaped(batch, seq, numHeads, headDim)
            .transposed(0, 2, 1, 3)

        let attn = MLXFast.scaledDotProductAttention(
            queries: q,
            keys: k,
            values: v,
            scale: scale,
            mask: attentionMask
        )

        let merged = attn.transposed(0, 2, 1, 3).reshaped(batch, seq, hiddenSize)
        return outProj(merged)
    }
}

final class PPDocLayoutV3EncoderLayerCore: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: PPDocLayoutV3SelfAttentionCore
    @ModuleInfo(key: "self_attn_layer_norm") var selfAttnLayerNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm

    private let normalizeBefore: Bool
    private let activation: PPDocLayoutV3Activation

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        normalizeBefore = modelConfig.normalizeBefore
        activation = PPDocLayoutV3Activation(modelConfig.encoderActivationFunction)

        let hiddenSize = modelConfig.encoderHiddenDim
        _selfAttn.wrappedValue = PPDocLayoutV3SelfAttentionCore(hiddenSize: hiddenSize, numHeads: modelConfig.encoderAttentionHeads)

        let lnEps = Float(modelConfig.layerNormEps ?? 1e-5)
        _selfAttnLayerNorm.wrappedValue = LayerNorm(dimensions: hiddenSize, eps: lnEps)
        _fc1.wrappedValue = Linear(hiddenSize, modelConfig.encoderFFNDim, bias: true)
        _fc2.wrappedValue = Linear(modelConfig.encoderFFNDim, hiddenSize, bias: true)
        _finalLayerNorm.wrappedValue = LayerNorm(dimensions: hiddenSize, eps: lnEps)
        super.init()
    }

    func forward(
        _ hiddenStates: MLXArray,
        attentionMask: MLXArray? = nil,
        spatialPositionEmbeddings: MLXArray? = nil
    ) -> MLXArray {
        var hiddenStates = hiddenStates

        var residual = hiddenStates
        if normalizeBefore {
            hiddenStates = selfAttnLayerNorm(hiddenStates)
        }

        hiddenStates = selfAttn.forward(
            hiddenStates: hiddenStates,
            attentionMask: attentionMask,
            positionEmbeddings: spatialPositionEmbeddings
        )

        hiddenStates = residual + hiddenStates
        if !normalizeBefore {
            hiddenStates = selfAttnLayerNorm(hiddenStates)
        }

        if normalizeBefore {
            hiddenStates = finalLayerNorm(hiddenStates)
        }

        residual = hiddenStates
        hiddenStates = fc2(activation(fc1(hiddenStates)))
        hiddenStates = residual + hiddenStates

        if !normalizeBefore {
            hiddenStates = finalLayerNorm(hiddenStates)
        }

        return hiddenStates
    }
}

struct PPDocLayoutV3SinePositionEmbedding: Sendable {
    let embedDim: Int
    let temperature: Float

    func callAsFunction(width: Int, height: Int, dtype: DType) -> MLXArray {
        precondition(embedDim % 4 == 0, "embedDim must be divisible by 4 for 2D sin-cos position embedding")
        let posDim = embedDim / 4

        let gridW = arange(0, width, dtype: dtype)
        let gridH = arange(0, height, dtype: dtype)
        let grids = meshGrid([gridW, gridH], indexing: .xy)
        let xx = grids[0]
        let yy = grids[1]

        let omega = arange(0, posDim, dtype: dtype) / Float(posDim).asMLXArray(dtype: dtype)
        let invTemp = exp(-log(Float(temperature).asMLXArray(dtype: dtype)) * omega)

        let outW = xx.reshaped(height * width, 1) * invTemp.reshaped(1, posDim)
        let outH = yy.reshaped(height * width, 1) * invTemp.reshaped(1, posDim)

        let pos = concatenated(
            [
                sin(outH),
                cos(outH),
                sin(outW),
                cos(outW),
            ],
            axis: 1
        )

        return pos.reshaped(1, height * width, embedDim)
    }
}

final class PPDocLayoutV3AIFILayerCore: Module, UnaryLayer {
    @ModuleInfo(key: "layers") var layers: [PPDocLayoutV3EncoderLayerCore]

    private let positionEmbedding: PPDocLayoutV3SinePositionEmbedding

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        positionEmbedding = PPDocLayoutV3SinePositionEmbedding(
            embedDim: modelConfig.encoderHiddenDim,
            temperature: Float(modelConfig.positionalEncodingTemperature)
        )

        let layerCount = max(modelConfig.encoderLayers, 0)
        _layers.wrappedValue = (0 ..< layerCount).map { _ in PPDocLayoutV3EncoderLayerCore(modelConfig: modelConfig) }
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let batch = x.dim(0)
        let height = x.dim(1)
        let width = x.dim(2)
        let channels = x.dim(3)

        var hiddenStates = x.reshaped(batch, height * width, channels)
        let posEmbed = positionEmbedding(width: width, height: height, dtype: hiddenStates.dtype)

        for layer in layers {
            hiddenStates = layer.forward(hiddenStates, attentionMask: nil, spatialPositionEmbeddings: posEmbed)
        }

        return hiddenStates.reshaped(batch, height, width, channels)
    }
}

final class PPDocLayoutV3ConvNormLayerCore: Module, UnaryLayer {
    @ModuleInfo(key: "conv") var conv: Conv2d
    @ModuleInfo(key: "norm") var norm: BatchNorm

    private let activation: PPDocLayoutV3Activation

    init(
        modelConfig: PPDocLayoutV3ModelConfig,
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int,
        stride: Int,
        padding: Int? = nil,
        activation: String? = nil
    ) {
        self.activation = PPDocLayoutV3Activation(activation)

        let bnEps = Float(modelConfig.batchNormEps ?? 1e-5)
        let pad = padding ?? (kernelSize - 1) / 2
        _conv.wrappedValue = Conv2d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: .init(kernelSize),
            stride: .init(stride),
            padding: .init(pad),
            bias: false
        )
        _norm.wrappedValue = BatchNorm(featureCount: outChannels, eps: bnEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        activation(norm(conv(x)))
    }
}

final class PPDocLayoutV3RepVggBlockCore: Module, UnaryLayer {
    @ModuleInfo(key: "conv1") var conv1: PPDocLayoutV3ConvNormLayerCore
    @ModuleInfo(key: "conv2") var conv2: PPDocLayoutV3ConvNormLayerCore

    private let activation: PPDocLayoutV3Activation

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        let hiddenChannels = Int(Double(modelConfig.encoderHiddenDim) * modelConfig.hiddenExpansion)
        _conv1.wrappedValue = PPDocLayoutV3ConvNormLayerCore(
            modelConfig: modelConfig,
            inChannels: hiddenChannels,
            outChannels: hiddenChannels,
            kernelSize: 3,
            stride: 1,
            padding: 1,
            activation: nil
        )
        _conv2.wrappedValue = PPDocLayoutV3ConvNormLayerCore(
            modelConfig: modelConfig,
            inChannels: hiddenChannels,
            outChannels: hiddenChannels,
            kernelSize: 1,
            stride: 1,
            padding: 0,
            activation: nil
        )
        activation = PPDocLayoutV3Activation(modelConfig.activationFunction)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        activation(conv1(x) + conv2(x))
    }
}

final class PPDocLayoutV3CSPRepLayerCore: Module, UnaryLayer {
    @ModuleInfo(key: "conv1") var conv1: PPDocLayoutV3ConvNormLayerCore
    @ModuleInfo(key: "conv2") var conv2: PPDocLayoutV3ConvNormLayerCore
    @ModuleInfo(key: "bottlenecks") var bottlenecks: [PPDocLayoutV3RepVggBlockCore]
    @ModuleInfo(key: "conv3") var conv3: Module

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        let inChannels = modelConfig.encoderHiddenDim * 2
        let outChannels = modelConfig.encoderHiddenDim
        let numBlocks = 3

        let hiddenChannels = Int(Double(outChannels) * modelConfig.hiddenExpansion)
        let activation = modelConfig.activationFunction

        _conv1.wrappedValue = PPDocLayoutV3ConvNormLayerCore(
            modelConfig: modelConfig,
            inChannels: inChannels,
            outChannels: hiddenChannels,
            kernelSize: 1,
            stride: 1,
            padding: 0,
            activation: activation
        )
        _conv2.wrappedValue = PPDocLayoutV3ConvNormLayerCore(
            modelConfig: modelConfig,
            inChannels: inChannels,
            outChannels: hiddenChannels,
            kernelSize: 1,
            stride: 1,
            padding: 0,
            activation: activation
        )

        _bottlenecks.wrappedValue = (0 ..< numBlocks).map { _ in PPDocLayoutV3RepVggBlockCore(modelConfig: modelConfig) }

        if hiddenChannels != outChannels {
            _conv3.wrappedValue = PPDocLayoutV3ConvNormLayerCore(
                modelConfig: modelConfig,
                inChannels: hiddenChannels,
                outChannels: outChannels,
                kernelSize: 1,
                stride: 1,
                padding: 0,
                activation: activation
            )
        } else {
            _conv3.wrappedValue = Identity()
        }

        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var hidden1 = conv1(x)
        for block in bottlenecks {
            hidden1 = block(hidden1)
        }
        let hidden2 = conv2(x)

        guard let conv3 = conv3 as? UnaryLayer else {
            fatalError("conv3 does not conform to UnaryLayer")
        }
        return conv3(hidden1 + hidden2)
    }
}

final class PPDocLayoutV3ConvLayerCore: Module, UnaryLayer {
    @ModuleInfo(key: "convolution") var convolution: Conv2d
    @ModuleInfo(key: "normalization") var normalization: BatchNorm

    private let activation: PPDocLayoutV3Activation

    init(
        modelConfig: PPDocLayoutV3ModelConfig,
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int,
        stride: Int,
        activation: String
    ) {
        let bnEps = Float(modelConfig.batchNormEps ?? 1e-5)
        self.activation = PPDocLayoutV3Activation(activation)
        _convolution.wrappedValue = Conv2d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: .init(kernelSize),
            stride: .init(stride),
            padding: .init(kernelSize / 2),
            bias: false
        )
        _normalization.wrappedValue = BatchNorm(featureCount: outChannels, eps: bnEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        activation(normalization(convolution(x)))
    }
}

final class PPDocLayoutV3ScaleHeadCore: Module, UnaryLayer {
    @ModuleInfo(key: "layers") var layers: [Module]

    init(
        modelConfig: PPDocLayoutV3ModelConfig,
        inChannels: Int,
        featureChannels: Int,
        fpnStride: Int,
        baseStride: Int
    ) {
        let headLength = max(1, Int(log2(Double(fpnStride)) - log2(Double(baseStride))))

        var layerModules: [Module] = []
        layerModules.reserveCapacity(headLength * 2)

        for k in 0 ..< headLength {
            let tempIn = (k == 0) ? inChannels : featureChannels
            layerModules.append(
                PPDocLayoutV3ConvLayerCore(
                    modelConfig: modelConfig,
                    inChannels: tempIn,
                    outChannels: featureChannels,
                    kernelSize: 3,
                    stride: 1,
                    activation: "silu"
                )
            )
            if fpnStride != baseStride {
                layerModules.append(Upsample(scaleFactor: 2.0, mode: .linear(alignCorners: false)))
            }
        }

        _layers.wrappedValue = layerModules
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        for layer in layers {
            guard let unary = layer as? UnaryLayer else {
                fatalError("PPDocLayoutV3ScaleHeadCore.layers contains non-UnaryLayer module: \(type(of: layer))")
            }
            x = unary(x)
        }
        return x
    }
}

final class PPDocLayoutV3MaskFeatFPNCore: Module {
    @ModuleInfo(key: "scale_heads") var scaleHeads: [PPDocLayoutV3ScaleHeadCore]
    @ModuleInfo(key: "output_conv") var outputConv: PPDocLayoutV3ConvLayerCore

    private let reorderIndex: [Int]
    private let fpnStrides: [Int]

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        let featureStrides = modelConfig.featureStrides
        let reorderIndex = featureStrides.enumerated().sorted { $0.element < $1.element }.map(\.offset)
        self.reorderIndex = reorderIndex
        let fpnStrides = reorderIndex.map { featureStrides[$0] }
        self.fpnStrides = fpnStrides

        let inChannels = Array(repeating: modelConfig.encoderHiddenDim, count: fpnStrides.count)
        let featureChannels = modelConfig.maskFeatureChannels[0]
        let outChannels = modelConfig.maskFeatureChannels[1]
        let baseStride = fpnStrides.first ?? 1

        _scaleHeads.wrappedValue = zip(inChannels, fpnStrides).map { inC, stride in
            PPDocLayoutV3ScaleHeadCore(
                modelConfig: modelConfig,
                inChannels: inC,
                featureChannels: featureChannels,
                fpnStride: stride,
                baseStride: baseStride
            )
        }

        _outputConv.wrappedValue = PPDocLayoutV3ConvLayerCore(
            modelConfig: modelConfig,
            inChannels: featureChannels,
            outChannels: outChannels,
            kernelSize: 3,
            stride: 1,
            activation: "silu"
        )

        super.init()
    }

    func forward(_ inputs: [MLXArray]) -> MLXArray {
        let reordered = reorderIndex.map { inputs[$0] }
        var output = scaleHeads[0](reordered[0])

        let targetH = output.dim(1)
        let targetW = output.dim(2)

        if reordered.count > 1 {
            for idx in 1 ..< reordered.count {
                let scaled = scaleHeads[idx](reordered[idx])
                let resized = resizeBilinear(scaled, toHeight: targetH, toWidth: targetW)
                output += resized
            }
        }

        return outputConv(output)
    }

    private func resizeBilinear(_ x: MLXArray, toHeight: Int, toWidth: Int) -> MLXArray {
        let h = x.dim(1)
        let w = x.dim(2)
        if h == toHeight, w == toWidth { return x }

        let scaleH = Float(toHeight) / Float(max(h, 1))
        let scaleW = Float(toWidth) / Float(max(w, 1))
        return Upsample(scaleFactor: [scaleH, scaleW], mode: .linear(alignCorners: false))(x)
    }
}

final class PPDocLayoutV3EncoderMaskOutputCore: Module, UnaryLayer {
    @ModuleInfo(key: "base_conv") var baseConv: PPDocLayoutV3ConvLayerCore
    @ModuleInfo(key: "conv") var conv: Conv2d

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        let inChannels = modelConfig.maskFeatureChannels[1]
        _baseConv.wrappedValue = PPDocLayoutV3ConvLayerCore(
            modelConfig: modelConfig,
            inChannels: inChannels,
            outChannels: inChannels,
            kernelSize: 3,
            stride: 1,
            activation: "silu"
        )
        _conv.wrappedValue = Conv2d(
            inputChannels: inChannels,
            outputChannels: modelConfig.numPrototypes,
            kernelSize: 1,
            stride: 1,
            padding: 0,
            bias: true
        )
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        conv(baseConv(x))
    }
}

struct PPDocLayoutV3HybridEncoderOutputs: @unchecked Sendable {
    var featureMaps: [MLXArray]
    var maskFeat: MLXArray
}

final class PPDocLayoutV3HybridEncoderCore: Module {
    @ModuleInfo(key: "downsample_convs") var downsampleConvs: [PPDocLayoutV3ConvNormLayerCore]
    @ModuleInfo(key: "encoder") var encoder: [PPDocLayoutV3AIFILayerCore]

    @ModuleInfo(key: "lateral_convs") var lateralConvs: [PPDocLayoutV3ConvNormLayerCore]
    @ModuleInfo(key: "fpn_blocks") var fpnBlocks: [PPDocLayoutV3CSPRepLayerCore]

    @ModuleInfo(key: "pan_blocks") var panBlocks: [PPDocLayoutV3CSPRepLayerCore]

    @ModuleInfo(key: "mask_feature_head") var maskFeatureHead: PPDocLayoutV3MaskFeatFPNCore
    @ModuleInfo(key: "encoder_mask_lateral") var encoderMaskLateral: PPDocLayoutV3ConvLayerCore
    @ModuleInfo(key: "encoder_mask_output") var encoderMaskOutput: PPDocLayoutV3EncoderMaskOutputCore

    private let encodeProjLayers: [Int]
    private let numFpnStages: Int

    init(modelConfig: PPDocLayoutV3ModelConfig) {
        encodeProjLayers = modelConfig.encodeProjLayers
        numFpnStages = max(modelConfig.encoderInChannels.count - 1, 0)

        let activation = modelConfig.activationFunction

        let aifiCount = encodeProjLayers.count
        _encoder.wrappedValue = (0 ..< aifiCount).map { _ in PPDocLayoutV3AIFILayerCore(modelConfig: modelConfig) }

        _lateralConvs.wrappedValue = (0 ..< numFpnStages).map { _ in
            PPDocLayoutV3ConvNormLayerCore(
                modelConfig: modelConfig,
                inChannels: modelConfig.encoderHiddenDim,
                outChannels: modelConfig.encoderHiddenDim,
                kernelSize: 1,
                stride: 1,
                padding: 0,
                activation: activation
            )
        }
        _fpnBlocks.wrappedValue = (0 ..< numFpnStages).map { _ in PPDocLayoutV3CSPRepLayerCore(modelConfig: modelConfig) }

        _downsampleConvs.wrappedValue = (0 ..< numFpnStages).map { _ in
            PPDocLayoutV3ConvNormLayerCore(
                modelConfig: modelConfig,
                inChannels: modelConfig.encoderHiddenDim,
                outChannels: modelConfig.encoderHiddenDim,
                kernelSize: 3,
                stride: 2,
                activation: activation
            )
        }
        _panBlocks.wrappedValue = (0 ..< numFpnStages).map { _ in PPDocLayoutV3CSPRepLayerCore(modelConfig: modelConfig) }

        _maskFeatureHead.wrappedValue = PPDocLayoutV3MaskFeatFPNCore(modelConfig: modelConfig)
        _encoderMaskLateral.wrappedValue = PPDocLayoutV3ConvLayerCore(
            modelConfig: modelConfig,
            inChannels: modelConfig.x4FeatDim,
            outChannels: modelConfig.maskFeatureChannels[1],
            kernelSize: 3,
            stride: 1,
            activation: "silu"
        )
        _encoderMaskOutput.wrappedValue = PPDocLayoutV3EncoderMaskOutputCore(modelConfig: modelConfig)
        super.init()
    }

    func forward(_ inputsEmbeds: [MLXArray], x4Feat: MLXArray) -> PPDocLayoutV3HybridEncoderOutputs {
        var featureMaps = inputsEmbeds

        if !encoder.isEmpty {
            for (i, encIndex) in encodeProjLayers.enumerated() where encIndex >= 0 && encIndex < featureMaps.count {
                featureMaps[encIndex] = encoder[i](featureMaps[encIndex])
            }
        }

        var fpnFeatureMaps: [MLXArray] = [featureMaps[featureMaps.count - 1]]
        if !fpnBlocks.isEmpty {
            for idx in 0 ..< fpnBlocks.count {
                let backboneIndex = numFpnStages - idx - 1
                let backboneFeatureMap = featureMaps[backboneIndex]
                var top = fpnFeatureMaps[fpnFeatureMaps.count - 1]
                top = lateralConvs[idx](top)
                fpnFeatureMaps[fpnFeatureMaps.count - 1] = top
                top = Upsample(scaleFactor: 2.0, mode: .nearest)(top)
                let fused = concatenated([top, backboneFeatureMap], axis: -1)
                let newFpn = fpnBlocks[idx](fused)
                fpnFeatureMaps.append(newFpn)
            }
        }
        fpnFeatureMaps.reverse()

        var panFeatureMaps: [MLXArray] = [fpnFeatureMaps[0]]
        if !panBlocks.isEmpty {
            for idx in 0 ..< panBlocks.count {
                let top = panFeatureMaps[panFeatureMaps.count - 1]
                let fpn = fpnFeatureMaps[idx + 1]
                let downsampled = downsampleConvs[idx](top)
                let fused = concatenated([downsampled, fpn], axis: -1)
                let newPan = panBlocks[idx](fused)
                panFeatureMaps.append(newPan)
            }
        }

        var maskFeat = maskFeatureHead.forward(panFeatureMaps)
        maskFeat = Upsample(scaleFactor: 2.0, mode: .linear(alignCorners: false))(maskFeat)
        maskFeat += encoderMaskLateral(x4Feat)
        maskFeat = encoderMaskOutput(maskFeat)

        return PPDocLayoutV3HybridEncoderOutputs(featureMaps: panFeatureMaps, maskFeat: maskFeat)
    }
}
