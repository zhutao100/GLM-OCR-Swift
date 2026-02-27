import Foundation
import MLX

enum GLMOCRFusionError: Error, Sendable {
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
        precondition(textEmbeddings.dim(0) == batch)
        precondition(visionEmbeddings.dim(0) == batch)

        let fused = textEmbeddings

        for b in 0..<batch {
            let rowIds = inputIds[b].asArray(Int32.self).map(Int.init)
            let positions = rowIds.enumerated().compactMap { i, id in id == imageTokenId ? i : nil }

            guard !positions.isEmpty else { throw GLMOCRFusionError.missingImageToken(tokenID: imageTokenId) }
            let expected = visionEmbeddings.dim(1)
            guard positions.count == expected else {
                throw GLMOCRFusionError.imageTokenCountMismatch(expected: expected, actual: positions.count)
            }

            for (i, pos) in positions.enumerated() {
                fused[b, pos] = visionEmbeddings[b, i]
            }
        }

        return fused
    }
}
