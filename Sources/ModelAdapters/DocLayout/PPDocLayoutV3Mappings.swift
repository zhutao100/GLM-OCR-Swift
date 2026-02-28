import Foundation
import VLMRuntimeKit

public enum LayoutTaskType: String, Sendable, Codable, Equatable {
    case text
    case table
    case formula
    case skip
    case abandon
}

/// Label policies mirrored from the official `glmocr/config.yaml`.
public enum PPDocLayoutV3Mappings {
    /// Detected native label → task type (text/table/formula/skip/abandon).
    public static let labelTaskMapping: [String: LayoutTaskType] = [
        // text
        "abstract": .text,
        "algorithm": .text,
        "content": .text,
        "doc_title": .text,
        "figure_title": .text,
        "paragraph_title": .text,
        "reference_content": .text,
        "text": .text,
        "vertical_text": .text,
        "vision_footnote": .text,
        "seal": .text,
        "formula_number": .text,

        // table
        "table": .table,

        // formula
        "display_formula": .formula,
        "inline_formula": .formula,
        // HF `PaddlePaddle/PP-DocLayoutV3_safetensors` snapshots may collapse both
        // display+inline formula classes to the single label "formula" in `config.json`.
        // Treat it as an alias so we don't accidentally discard formula regions.
        "formula": .formula,

        // skip (keep region but don't OCR)
        "chart": .skip,
        "image": .skip,

        // abandon (discard region)
        "header": .abandon,
        "footer": .abandon,
        "number": .abandon,
        "footnote": .abandon,
        "aside_text": .abandon,
        "reference": .abandon,
        "footer_image": .abandon,
        "header_image": .abandon,
    ]

    /// Detected native label → visualization/formatting kind.
    public static let labelToVisualizationKind: [String: OCRRegionKind] = [
        // table
        "table": .table,

        // formula
        "display_formula": .formula,
        "inline_formula": .formula,
        "formula": .formula,

        // image
        "chart": .image,
        "image": .image,

        // text
        "abstract": .text,
        "algorithm": .text,
        "content": .text,
        "doc_title": .text,
        "figure_title": .text,
        "paragraph_title": .text,
        "reference_content": .text,
        "text": .text,
        "vertical_text": .text,
        "vision_footnote": .text,
        "seal": .text,
        "formula_number": .text,
    ]
}
