import Foundation
import MLX
import MLXNN
import VLMRuntimeKit

final class GLMOCRSelfAttention: Module {
    private let heads: Int
    private let kvHeads: Int
    private let headDim: Int
    private let scale: Float

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear

    init(hiddenSize: Int, numHeads: Int, numKeyValueHeads: Int, headDim: Int) {
        precondition(numHeads % numKeyValueHeads == 0, "numHeads must be divisible by numKeyValueHeads")

        heads = numHeads
        kvHeads = numKeyValueHeads
        self.headDim = headDim
        scale = 1.0 / sqrt(Float(headDim))

        _wq.wrappedValue = Linear(hiddenSize, numHeads * headDim, bias: false)
        _wk.wrappedValue = Linear(hiddenSize, numKeyValueHeads * headDim, bias: false)
        _wv.wrappedValue = Linear(hiddenSize, numKeyValueHeads * headDim, bias: false)
        _wo.wrappedValue = Linear(numHeads * headDim, hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cos: MLXArray,
        sin: MLXArray,
        rotaryDim: Int,
        cache: KVCacheSimple? = nil
    ) -> MLXArray {
        let (batch, seqLen) = (x.dim(0), x.dim(1))

        var q = wq(x).reshaped(batch, seqLen, heads, headDim).transposed(0, 2, 1, 3)  // [B, H, S, D]
        var k = wk(x).reshaped(batch, seqLen, kvHeads, headDim).transposed(0, 2, 1, 3)  // [B, KvH, S, D]
        let v = wv(x).reshaped(batch, seqLen, kvHeads, headDim).transposed(0, 2, 1, 3)

        // Apply GLM-style interleaved RoPE to the first `rotaryDim` features.
        if rotaryDim > 0 {
            let rd = min(rotaryDim, headDim)
            let qRot = q[0..., 0..., 0..., ..<rd]
            let qPass = rd < headDim ? q[0..., 0..., 0..., rd...] : nil
            let kRot = k[0..., 0..., 0..., ..<rd]
            let kPass = rd < headDim ? k[0..., 0..., 0..., rd...] : nil

            let cosSlice = cos[0..., 0..., 0..., ..<rd]
            let sinSlice = sin[0..., 0..., 0..., ..<rd]

            let qEmbed = (qRot * cosSlice) + (GLMOCRRotary.rotateHalfInterleaved(qRot) * sinSlice)
            let kEmbed = (kRot * cosSlice) + (GLMOCRRotary.rotateHalfInterleaved(kRot) * sinSlice)

            q = qPass.map { concatenated([qEmbed, $0], axis: -1) } ?? qEmbed
            k = kPass.map { concatenated([kEmbed, $0], axis: -1) } ?? kEmbed
        }

        let keys: MLXArray
        let values: MLXArray
        if let cache {
            (keys, values) = cache.update(keys: k, values: v)
        } else {
            keys = k
            values = v
        }

        let effectiveMask: MLXFast.ScaledDotProductAttentionMaskMode =
            if let cache, cache.offset > 0, seqLen == 1 {
                .none
            } else {
                mask
            }

        let attn = MLXFast.scaledDotProductAttention(
            queries: q,
            keys: keys,
            values: values,
            scale: scale,
            mask: effectiveMask
        )

        let merged = attn.transposed(0, 2, 1, 3).reshaped(batch, seqLen, heads * headDim)
        return wo(merged)
    }
}

final class GLMOCRMLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_up_proj") var gateUp: Linear
    @ModuleInfo(key: "down_proj") var down: Linear

    private let intermediateSize: Int

    init(hiddenSize: Int, intermediateSize: Int) {
        self.intermediateSize = intermediateSize
        _gateUp.wrappedValue = Linear(hiddenSize, intermediateSize * 2, bias: false)
        _down.wrappedValue = Linear(intermediateSize, hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let packed = gateUp(x)
        let gate = packed[0..., 0..., ..<intermediateSize]
        let up = packed[0..., 0..., intermediateSize...]
        return down(silu(gate) * up)
    }
}

final class GLMOCRDecoderLayer: Module {
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "self_attn") var selfAttn: GLMOCRSelfAttention
    @ModuleInfo(key: "post_self_attn_layernorm") var postSelfAttnLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm
    @ModuleInfo(key: "mlp") var mlp: GLMOCRMLP
    @ModuleInfo(key: "post_mlp_layernorm") var postMlpLayerNorm: RMSNorm

    init(
        hiddenSize: Int,
        intermediateSize: Int,
        numHeads: Int,
        numKeyValueHeads: Int,
        headDim: Int,
        normEps: Float
    ) {
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: normEps)
        _selfAttn.wrappedValue = GLMOCRSelfAttention(
            hiddenSize: hiddenSize,
            numHeads: numHeads,
            numKeyValueHeads: numKeyValueHeads,
            headDim: headDim
        )
        _postSelfAttnLayerNorm.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: normEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: normEps)
        _mlp.wrappedValue = GLMOCRMLP(hiddenSize: hiddenSize, intermediateSize: intermediateSize)
        _postMlpLayerNorm.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: normEps)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cos: MLXArray,
        sin: MLXArray,
        rotaryDim: Int,
        cache: KVCacheSimple? = nil
    ) -> MLXArray {
        let residual1 = x
        var h = inputLayerNorm(x)
        h = selfAttn(h, mask: mask, cos: cos, sin: sin, rotaryDim: rotaryDim, cache: cache)
        h = postSelfAttnLayerNorm(h)
        h = residual1 + h

        let residual2 = h
        var mlpOut = postAttentionLayerNorm(h)
        mlpOut = mlp(mlpOut)
        mlpOut = postMlpLayerNorm(mlpOut)
        h = residual2 + mlpOut
        return h
    }
}

final class GLMOCRLanguageModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    var layers: [GLMOCRDecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    private let rotaryEmbedding: GLMOCRTextRotaryEmbedding

    let vocabSize: Int
    let hiddenSize: Int

    init(config: GLMOCRConfig.TextConfig) throws {
        guard let vocabSize = config.vocabSize else {
            throw GLMOCRModelError.configurationError("text_config.vocab_size missing")
        }
        guard let hiddenSize = config.hiddenSize else {
            throw GLMOCRModelError.configurationError("text_config.hidden_size missing")
        }
        guard let numLayers = config.numHiddenLayers else {
            throw GLMOCRModelError.configurationError("text_config.num_hidden_layers missing")
        }
        guard let numHeads = config.numAttentionHeads else {
            throw GLMOCRModelError.configurationError("text_config.num_attention_heads missing")
        }
        guard let numKVHeads = config.numKeyValueHeads else {
            throw GLMOCRModelError.configurationError("text_config.num_key_value_heads missing")
        }
        guard let headDim = config.headDim else {
            throw GLMOCRModelError.configurationError("text_config.head_dim missing")
        }
        guard let intermediateSize = config.intermediateSize else {
            throw GLMOCRModelError.configurationError("text_config.intermediate_size missing")
        }

        let ropeTheta = config.ropeParameters?.ropeTheta ?? 10000
        let partialRotaryFactor = config.ropeParameters?.partialRotaryFactor ?? 1.0
        let mropeSection = config.ropeParameters?.mropeSection
        let normEps = config.rmsNormEps ?? 1e-5

        self.vocabSize = vocabSize
        self.hiddenSize = hiddenSize
        rotaryEmbedding = GLMOCRTextRotaryEmbedding(
            headDim: headDim,
            ropeTheta: ropeTheta,
            partialRotaryFactor: partialRotaryFactor,
            mropeSection: mropeSection
        )

        _embedTokens.wrappedValue = Embedding(embeddingCount: vocabSize, dimensions: hiddenSize)
        layers = (0..<numLayers).map { _ in
            GLMOCRDecoderLayer(
                hiddenSize: hiddenSize,
                intermediateSize: intermediateSize,
                numHeads: numHeads,
                numKeyValueHeads: numKVHeads,
                headDim: headDim,
                normEps: normEps
            )
        }
        _norm.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: normEps)

        super.init()
    }

    func embed(_ inputIds: MLXArray) -> MLXArray {
        embedTokens(inputIds)
    }

    func decode(_ embeddings: MLXArray) -> MLXArray {
        decode(embeddings, mask: .causal, caches: nil, positionIds: nil)
    }

    func decode(
        _ embeddings: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        caches: [KVCacheSimple]?,
        positionIds: MLXArray?
    ) -> MLXArray {
        let batch = embeddings.dim(0)
        let seqLen = embeddings.dim(1)

        let ids: MLXArray
        if let positionIds {
            ids = positionIds
        } else {
            let base = MLXArray(Array(0..<seqLen)).reshaped(1, 1, seqLen)
            ids = broadcast(base, to: [3, batch, seqLen])
        }

        let (cosBase, sinBase) = rotaryEmbedding.cosSin(positionIds: ids, dtype: embeddings.dtype)
        let cos = cosBase.expandedDimensions(axis: 1)  // [B, 1, S, rotaryDim]
        let sin = sinBase.expandedDimensions(axis: 1)

        var h = embeddings
        if let caches {
            precondition(caches.count == layers.count, "cache count must match layer count")
            for (idx, layer) in layers.enumerated() {
                h = layer(h, mask: mask, cos: cos, sin: sin, rotaryDim: rotaryEmbedding.rotaryDim, cache: caches[idx])
            }
        } else {
            for layer in layers {
                h = layer(h, mask: mask, cos: cos, sin: sin, rotaryDim: rotaryEmbedding.rotaryDim)
            }
        }
        return norm(h)
    }

    func callAsFunction(_ inputIds: MLXArray) -> MLXArray {
        decode(embed(inputIds))
    }
}
