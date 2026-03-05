import Foundation
import MLX

enum GLMOCRFusionError: Error, Sendable, Equatable {
    case missingImageToken(tokenID: Int)
    case imageTokenCountMismatch(expected: Int, actual: Int)
}

enum GLMOCRFusion {
    /// Replace token embeddings at `<|image|>` positions with vision embeddings.
    ///
    /// - Parameters:
    ///   - inputIds: `[B, S]` token IDs.
    ///   - textEmbeddings: `[B, S, H]` token embeddings.
    ///   - visionEmbeddings: `[B, N, H]` vision embeddings for the image.
    ///   - imageTokenId: token ID used as image placeholder (`<|image|>`).
    ///
    /// The replacement requires `count(<|image|>) == N` per batch row.
    static func fuse(
        inputIds: MLXArray,
        textEmbeddings: MLXArray,
        visionEmbeddings: MLXArray,
        imageTokenId: Int
    ) throws -> MLXArray {
        let batch = inputIds.dim(0)
        let seqLen = inputIds.dim(1)
        precondition(textEmbeddings.dim(0) == batch)
        precondition(visionEmbeddings.dim(0) == batch)
        precondition(textEmbeddings.dim(1) == seqLen)
        precondition(textEmbeddings.dim(2) == visionEmbeddings.dim(2))

        let expected = visionEmbeddings.dim(1)
        let hidden = textEmbeddings.dim(2)

        let tokenIdScalar = Int32(imageTokenId).asMLXArray(dtype: inputIds.dtype)
        let mask = inputIds .== tokenIdScalar  // [B, S]

        // Validate counts per row on host (B is tiny).
        let counts = mask.asType(.int32).sum(axis: 1).asArray(Int32.self).map(Int.init)
        if counts.contains(0) {
            throw GLMOCRFusionError.missingImageToken(tokenID: imageTokenId)
        }
        if let mismatch = counts.first(where: { $0 != expected }) {
            throw GLMOCRFusionError.imageTokenCountMismatch(expected: expected, actual: mismatch)
        }

        let featureIndex = cumsum(mask.asType(.int32), axis: 1) - Int32(1).asMLXArray(dtype: .int32)  // [B, S]
        let safeIndex = which(mask, featureIndex, MLXArray.zeros([batch, seqLen], dtype: .int32))

        let offsets =
            MLXArray(Array(0..<batch))
            .asType(.int32)
            .reshaped(batch, 1) * Int32(expected).asMLXArray(dtype: .int32)

        let flatIndex = (safeIndex + offsets).reshaped(batch * seqLen)

        let flatVision = visionEmbeddings.reshaped(batch * expected, hidden)
        let gathered = flatVision[flatIndex]  // [B*S, H]

        let flatText = textEmbeddings.reshaped(batch * seqLen, hidden)
        let outFlat = which(mask.reshaped(batch * seqLen, 1), gathered, flatText)
        return outFlat.reshaped(batch, seqLen, hidden)
    }
}
