import Foundation
import MLX
import MLXNN

final class GLMOCRVisionPatchEmbed: Module {
    @ModuleInfo(key: "proj") var proj: Conv3d

    init(inChannels: Int, hiddenSize: Int, temporalPatchSize: Int, patchSize: Int) {
        _proj.wrappedValue = Conv3d(
            inputChannels: inChannels,
            outputChannels: hiddenSize,
            kernelSize: .init((temporalPatchSize, patchSize, patchSize)),
            stride: .init((temporalPatchSize, patchSize, patchSize)),
            padding: 0,
            bias: true
        )
        super.init()
    }

    func callAsFunction(_ pixelValues: MLXArray) -> MLXArray {
        proj(pixelValues)
    }
}

final class GLMOCRVisionAttention: Module {
    private let heads: Int
    private let headDim: Int
    private let scale: Float

    @ModuleInfo(key: "qkv") var qkv: Linear
    @ModuleInfo(key: "proj") var proj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    init(hiddenSize: Int, numHeads: Int, normEps: Float) {
        precondition(hiddenSize % numHeads == 0, "hiddenSize must be divisible by numHeads")

        heads = numHeads
        headDim = hiddenSize / numHeads
        scale = 1.0 / sqrt(Float(headDim))

        _qkv.wrappedValue = Linear(hiddenSize, hiddenSize * 3, bias: true)
        _proj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: true)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: normEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: normEps)

        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let (batch, seqLen, hidden) = (x.dim(0), x.dim(1), x.dim(2))
        precondition(hidden == heads * headDim)

        let packed = qkv(x) // [B, S, 3H]

        let q = packed[0..., 0..., ..<hidden]
        let k = packed[0..., 0..., hidden ..< (hidden * 2)]
        let v = packed[0..., 0..., (hidden * 2)...]

        var qh = q.reshaped(batch, seqLen, heads, headDim).transposed(0, 2, 1, 3)
        var kh = k.reshaped(batch, seqLen, heads, headDim).transposed(0, 2, 1, 3)
        let vh = v.reshaped(batch, seqLen, heads, headDim).transposed(0, 2, 1, 3)

        qh = qNorm(qh)
        kh = kNorm(kh)

        let attn = MLXFast.scaledDotProductAttention(
            queries: qh,
            keys: kh,
            values: vh,
            scale: scale,
            mask: .none
        )

        let merged = attn.transposed(0, 2, 1, 3).reshaped(batch, seqLen, hidden)
        return proj(merged)
    }
}

final class GLMOCRVisionMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "up_proj") var up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear

    init(hiddenSize: Int, intermediateSize: Int) {
        _gate.wrappedValue = Linear(hiddenSize, intermediateSize, bias: true)
        _up.wrappedValue = Linear(hiddenSize, intermediateSize, bias: true)
        _down.wrappedValue = Linear(intermediateSize, hiddenSize, bias: true)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

final class GLMOCRVisionBlock: Module {
    @ModuleInfo(key: "norm1") var norm1: RMSNorm
    @ModuleInfo(key: "attn") var attn: GLMOCRVisionAttention
    @ModuleInfo(key: "norm2") var norm2: RMSNorm
    @ModuleInfo(key: "mlp") var mlp: GLMOCRVisionMLP

    init(hiddenSize: Int, intermediateSize: Int, numHeads: Int, normEps: Float) {
        _norm1.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: normEps)
        _attn.wrappedValue = GLMOCRVisionAttention(hiddenSize: hiddenSize, numHeads: numHeads, normEps: normEps)
        _norm2.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: normEps)
        _mlp.wrappedValue = GLMOCRVisionMLP(hiddenSize: hiddenSize, intermediateSize: intermediateSize)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = x + attn(norm1(x))
        return h + mlp(norm2(h))
    }
}

final class GLMOCRVisionMerger: Module {
    @ModuleInfo(key: "proj") var proj: Linear
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "up_proj") var up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "post_projection_norm") var postProjectionNorm: LayerNorm

    init(hiddenSize: Int, intermediateSize: Int, normEps: Float) {
        _proj.wrappedValue = Linear(hiddenSize, hiddenSize, bias: false)
        _gate.wrappedValue = Linear(hiddenSize, intermediateSize, bias: false)
        _up.wrappedValue = Linear(hiddenSize, intermediateSize, bias: false)
        _down.wrappedValue = Linear(intermediateSize, hiddenSize, bias: false)
        _postProjectionNorm.wrappedValue = LayerNorm(dimensions: hiddenSize, eps: normEps, affine: true, bias: true)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = proj(x)
        let mlpOut = down(silu(gate(h)) * up(h))
        return postProjectionNorm(h + mlpOut)
    }
}

final class GLMOCRVisionModel: Module {
    @ModuleInfo(key: "patch_embed") var patchEmbed: GLMOCRVisionPatchEmbed
    var blocks: [GLMOCRVisionBlock]
    @ModuleInfo(key: "post_layernorm") var postLayerNorm: RMSNorm
    @ModuleInfo(key: "downsample") var downsample: Conv2d
    @ModuleInfo(key: "merger") var merger: GLMOCRVisionMerger

    let imageSize: Int
    let patchSize: Int
    let temporalPatchSize: Int
    let spatialMergeSize: Int

    init(config: GLMOCRConfig.VisionConfig) throws {
        guard let hiddenSize = config.hiddenSize else {
            throw GLMOCRModelError.configurationError("vision_config.hidden_size missing")
        }
        guard let depth = config.depth else {
            throw GLMOCRModelError.configurationError("vision_config.depth missing")
        }
        guard let numHeads = config.numHeads else {
            throw GLMOCRModelError.configurationError("vision_config.num_heads missing")
        }
        guard let intermediateSize = config.intermediateSize else {
            throw GLMOCRModelError.configurationError("vision_config.intermediate_size missing")
        }
        let normEps = config.rmsNormEps ?? 1e-5

        guard let imageSize = config.imageSize else {
            throw GLMOCRModelError.configurationError("vision_config.image_size missing")
        }
        guard let patchSize = config.patchSize else {
            throw GLMOCRModelError.configurationError("vision_config.patch_size missing")
        }
        guard let temporalPatchSize = config.temporalPatchSize else {
            throw GLMOCRModelError.configurationError("vision_config.temporal_patch_size missing")
        }
        guard let spatialMergeSize = config.spatialMergeSize else {
            throw GLMOCRModelError.configurationError("vision_config.spatial_merge_size missing")
        }

        self.imageSize = imageSize
        self.patchSize = patchSize
        self.temporalPatchSize = temporalPatchSize
        self.spatialMergeSize = spatialMergeSize

        _patchEmbed.wrappedValue = GLMOCRVisionPatchEmbed(
            inChannels: 3,
            hiddenSize: hiddenSize,
            temporalPatchSize: temporalPatchSize,
            patchSize: patchSize
        )

        blocks = (0 ..< depth).map { _ in
            GLMOCRVisionBlock(
                hiddenSize: hiddenSize,
                intermediateSize: intermediateSize,
                numHeads: numHeads,
                normEps: normEps
            )
        }

        _postLayerNorm.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: normEps)

        let outHiddenSize = config.outHiddenSize ?? hiddenSize
        _downsample.wrappedValue = Conv2d(
            inputChannels: hiddenSize,
            outputChannels: outHiddenSize,
            kernelSize: .init(spatialMergeSize),
            stride: .init(spatialMergeSize),
            padding: 0,
            bias: true
        )

        _merger.wrappedValue = GLMOCRVisionMerger(
            hiddenSize: outHiddenSize,
            intermediateSize: 4608,
            normEps: normEps
        )

        super.init()
    }

    /// Returns fused vision embeddings with shape `[B, N, outHidden]`.
    func callAsFunction(_ pixelValues: MLXArray) -> MLXArray {
        // pixelValues expected shape: [B, D, H, W, C] (channels last)
        let patches = patchEmbed(pixelValues) // [B, D', H', W', hidden]
        let batch = patches.dim(0)
        let depth = patches.dim(1)
        let gridH = patches.dim(2)
        let gridW = patches.dim(3)
        let hidden = patches.dim(4)

        var x = patches.reshaped(batch, depth * gridH * gridW, hidden)
        for block in blocks {
            x = block(x)
        }
        x = postLayerNorm(x)

        // Downsample spatially (merge_size) and project to out_hidden_size.
        // For static images, depth is typically 1 after temporal patchify.
        let x2d = x.reshaped(batch, depth, gridH, gridW, hidden)
        // Merge depth into batch for 2D conv, then restore.
        let x2dFlat = x2d.reshaped(batch * depth, gridH, gridW, hidden)
        let down = downsample(x2dFlat) // [B*D, H/merge, W/merge, outHidden]

        let outHidden = down.dim(3)
        let downH = down.dim(1)
        let downW = down.dim(2)
        let downRestored = down.reshaped(batch, depth, downH, downW, outHidden)
        var tokens = downRestored.reshaped(batch, depth * downH * downW, outHidden)

        tokens = merger(tokens)
        return tokens
    }
}
