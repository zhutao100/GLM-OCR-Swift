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

    private let rope: RoPE

    init(hiddenSize: Int, numHeads: Int, numKeyValueHeads: Int, headDim: Int, ropeTheta: Float) {
        precondition(numHeads % numKeyValueHeads == 0, "numHeads must be divisible by numKeyValueHeads")

        heads = numHeads
        kvHeads = numKeyValueHeads
        self.headDim = headDim
        scale = 1.0 / sqrt(Float(headDim))

        _wq.wrappedValue = Linear(hiddenSize, numHeads * headDim, bias: false)
        _wk.wrappedValue = Linear(hiddenSize, numKeyValueHeads * headDim, bias: false)
        _wv.wrappedValue = Linear(hiddenSize, numKeyValueHeads * headDim, bias: false)
        _wo.wrappedValue = Linear(numHeads * headDim, hiddenSize, bias: false)

        rope = RoPE(dimensions: headDim, traditional: false, base: ropeTheta, scale: 1.0)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCacheSimple? = nil
    ) -> MLXArray {
        let (batch, seqLen) = (x.dim(0), x.dim(1))

        var q = wq(x).reshaped(batch, seqLen, heads, headDim).transposed(0, 2, 1, 3)
        var k = wk(x).reshaped(batch, seqLen, kvHeads, headDim).transposed(0, 2, 1, 3)
        let v = wv(x).reshaped(batch, seqLen, kvHeads, headDim).transposed(0, 2, 1, 3)

        let ropeOffset = cache?.offset ?? 0
        q = rope(q, offset: ropeOffset)
        k = rope(k, offset: ropeOffset)

        let keys: MLXArray
        let values: MLXArray
        if let cache {
            (keys, values) = cache.update(keys: k, values: v)
        } else {
            keys = k
            values = v
        }

        let effectiveMask: MLXFast.ScaledDotProductAttentionMaskMode = if cache != nil, ropeOffset > 0, seqLen == 1 {
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
        ropeTheta: Float,
        normEps: Float
    ) {
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: hiddenSize, eps: normEps)
        _selfAttn.wrappedValue = GLMOCRSelfAttention(
            hiddenSize: hiddenSize,
            numHeads: numHeads,
            numKeyValueHeads: numKeyValueHeads,
            headDim: headDim,
            ropeTheta: ropeTheta
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
        cache: KVCacheSimple? = nil
    ) -> MLXArray {
        var h = x + selfAttn(inputLayerNorm(x), mask: mask, cache: cache)
        h = postSelfAttnLayerNorm(h)
        h += mlp(postAttentionLayerNorm(h))
        h = postMlpLayerNorm(h)
        return h
    }
}

final class GLMOCRLanguageModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    var layers: [GLMOCRDecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

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
        let normEps = config.rmsNormEps ?? 1e-5

        self.vocabSize = vocabSize
        self.hiddenSize = hiddenSize

        _embedTokens.wrappedValue = Embedding(embeddingCount: vocabSize, dimensions: hiddenSize)
        layers = (0 ..< numLayers).map { _ in
            GLMOCRDecoderLayer(
                hiddenSize: hiddenSize,
                intermediateSize: intermediateSize,
                numHeads: numHeads,
                numKeyValueHeads: numKVHeads,
                headDim: headDim,
                ropeTheta: ropeTheta,
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
        decode(embeddings, mask: .causal, caches: nil)
    }

    func decode(
        _ embeddings: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        caches: [KVCacheSimple]?
    ) -> MLXArray {
        var h = embeddings
        if let caches {
            precondition(caches.count == layers.count, "cache count must match layer count")
            for (idx, layer) in layers.enumerated() {
                h = layer(h, mask: mask, cache: caches[idx])
            }
        } else {
            for layer in layers {
                h = layer(h, mask: mask)
            }
        }
        return norm(h)
    }

    func callAsFunction(_ inputIds: MLXArray) -> MLXArray {
        decode(embed(inputIds))
    }
}
