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
