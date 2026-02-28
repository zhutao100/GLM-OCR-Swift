import MLX

/// Small, deterministic pre-filters mirrored from the upstream GLM-OCR layout detector.
enum PPDocLayoutV3Prefilters {
    /// Mirror upstream min-size validity masking:
    /// suppress logits for boxes smaller than one mask cell before post-processing selection.
    ///
    /// Upstream reference: `glmocr/layout/layout_detector.py` (valid_mask + `masked_fill_(-100.0)`).
    static func maskLogitsForTinyBoxes(
        logits: MLXArray,
        predBoxes: MLXArray,
        maskHeight: Int,
        maskWidth: Int,
        fillLogit: Float = -100.0
    ) -> MLXArray {
        guard predBoxes.ndim == 3, predBoxes.dim(2) >= 4 else { return logits }

        let h = max(maskHeight, 1)
        let w = max(maskWidth, 1)
        let minNormW = (1.0 / Float(w)).asMLXArray(dtype: .float32)
        let minNormH = (1.0 / Float(h)).asMLXArray(dtype: .float32)

        let boxW = predBoxes[0..., 0..., 2].asType(.float32)
        let boxH = predBoxes[0..., 0..., 3].asType(.float32)
        let valid = logicalAnd(boxW .> minNormW, boxH .> minNormH).expandedDimensions(axis: -1)

        let fill = fillLogit.asMLXArray(dtype: logits.dtype)
        return which(valid, logits, fill)
    }
}
