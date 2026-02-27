import Foundation
import MLX
import MLXNN

enum GLMOCRRotary {
    static func rotateHalfInterleaved(_ x: MLXArray) -> MLXArray {
        let dim = x.dim(x.ndim - 1)
        precondition(dim % 2 == 0, "rotateHalfInterleaved requires an even last dimension")

        let x1 = x[0..., 0..., 0..., .stride(by: 2)]
        let x2 = x[0..., 0..., 0..., .stride(from: 1, by: 2)]
        let stacked = MLX.stacked([-x2, x1], axis: -1)

        var shape = x.shape
        shape[shape.count - 1] = dim
        return stacked.reshaped(shape)
    }

    static func rotateHalfSplit(_ x: MLXArray) -> MLXArray {
        let dim = x.dim(x.ndim - 1)
        precondition(dim % 2 == 0, "rotateHalfSplit requires an even last dimension")
        let half = dim / 2
        let x1 = x[0..., 0..., 0..., ..<half]
        let x2 = x[0..., 0..., 0..., half...]
        return concatenated([-x2, x1], axis: -1)
    }
}

/// GLM-OCR text rotary embedding with mRoPE section mixing (ported from Transformers `GlmOcrTextRotaryEmbedding`).
struct GLMOCRTextRotaryEmbedding: @unchecked Sendable {
    let rotaryDim: Int
    private let invFreq: MLXArray
    private let mropeSection: [Int]

    init(headDim: Int, ropeTheta: Float, partialRotaryFactor: Float, mropeSection: [Int]?) {
        let factor = max(min(partialRotaryFactor, 1.0), 0.0)
        var dim = Int((Float(headDim) * factor).rounded(.down))
        dim -= dim % 2
        rotaryDim = max(dim, 0)

        let half = max(rotaryDim / 2, 0)
        if half > 0 {
            let positions = (MLXArray(0..<half).asType(.float32) * 2) / Float(rotaryDim)
            invFreq = 1.0 / pow(ropeTheta, positions)
        } else {
            invFreq = MLXArray.zeros([0], dtype: .float32)
        }

        self.mropeSection = mropeSection ?? [8, 12, 12]
    }

    func cosSin(positionIds: MLXArray, dtype: DType) -> (cos: MLXArray, sin: MLXArray) {
        precondition(positionIds.ndim == 3, "positionIds must have shape [3, B, S]")
        precondition(positionIds.dim(0) == 3, "positionIds must have shape [3, B, S]")

        let batch = positionIds.dim(1)
        let seqLen = positionIds.dim(2)

        guard rotaryDim > 0 else {
            let empty = MLXArray.zeros([batch, seqLen, 0], dtype: dtype)
            return (empty, empty)
        }

        let pos = positionIds.asType(.float32)  // [3, B, S]
        let freqs = pos.expandedDimensions(axis: -1) * invFreq  // [3, B, S, rotaryDim/2]

        // Apply mRoPE section mixing: select temporal/height/width stream per section.
        let mixed = applyMrope(freqs: freqs, section: mropeSection)  // [B, S, rotaryDim/2]
        let emb = concatenated([mixed, mixed], axis: -1)  // [B, S, rotaryDim]

        let cosEmb = cos(emb)
        let sinEmb = sin(emb)

        let half = rotaryDim / 2
        let cosHalf = cosEmb[0..., 0..., ..<half]
        let sinHalf = sinEmb[0..., 0..., ..<half]

        // Interleave to match Transformers `repeat_interleave(2)` convention.
        let cosFull = MLX.stacked([cosHalf, cosHalf], axis: -1).reshaped(batch, seqLen, rotaryDim).asType(dtype)
        let sinFull = MLX.stacked([sinHalf, sinHalf], axis: -1).reshaped(batch, seqLen, rotaryDim).asType(dtype)
        return (cosFull, sinFull)
    }

    private func applyMrope(freqs: MLXArray, section: [Int]) -> MLXArray {
        precondition(freqs.ndim == 4, "freqs must have shape [3, B, S, D]")
        precondition(freqs.dim(0) == 3, "freqs must have shape [3, B, S, D]")

        let batch = freqs.dim(1)
        let seqLen = freqs.dim(2)
        let total = freqs.dim(3)

        var start = 0
        var chunks: [MLXArray] = []
        chunks.reserveCapacity(section.count)

        for (idx, size) in section.enumerated() where size > 0 {
            let end = min(start + size, total)
            guard end > start else { continue }
            let stream = idx % 3
            chunks.append(freqs[stream, 0..., 0..., start..<end])
            start = end
            if start >= total { break }
        }

        if chunks.isEmpty {
            return MLXArray.zeros([batch, seqLen, total], dtype: freqs.dtype)
        }
        return concatenated(chunks, axis: -1)
    }
}
