import Foundation
import VLMRuntimeKit

/// PP-DocLayout-V3 bbox conversion helpers.
///
/// The upstream GLM-OCR implementation normalizes pixel-space `xyxy` boxes into `[0, 1000]`
/// using truncation semantics (`int(...)`) for **all** edges. Do not expand the max edge with
/// ceil-like behavior, or crops will include extra pixels and drift parity on dense regions.
enum PPDocLayoutV3BBoxConversion {
    static func toNormalizedBBox(x1: Float, y1: Float, x2: Float, y2: Float) -> OCRNormalizedBBox {
        func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }

        let x1 = clamp01(x1)
        let y1 = clamp01(y1)
        let x2 = clamp01(x2)
        let y2 = clamp01(y2)

        // Match upstream `int(v * 1000)` truncation.
        let nx1 = Int(x1 * 1000)
        let ny1 = Int(y1 * 1000)
        let nx2 = Int(x2 * 1000)
        let ny2 = Int(y2 * 1000)

        return OCRNormalizedBBox(
            x1: max(0, min(1000, nx1)),
            y1: max(0, min(1000, ny1)),
            x2: max(0, min(1000, nx2)),
            y2: max(0, min(1000, ny2))
        )
    }
}
