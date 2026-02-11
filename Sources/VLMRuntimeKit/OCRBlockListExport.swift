import Foundation

/// Canonical block-list export schema used by the official GLM-OCR examples:
/// `[[{index,label,content,bbox_2d}, ...], ...]`.
public struct OCRBlockListItem: Sendable, Codable, Equatable {
    public var index: Int
    public var label: String
    public var content: String
    public var bbox2d: [Int]

    public init(index: Int, label: String, content: String, bbox2d: [Int]) {
        self.index = index
        self.label = label
        self.content = content
        self.bbox2d = bbox2d
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case label
        case content
        case bbox2d = "bbox_2d"
    }
}

public typealias OCRBlockListExport = [[OCRBlockListItem]]

public extension OCRDocument {
    /// Convert to the block-list schema used by the reference `examples/result/*/*.json`.
    func toBlockListExport() -> OCRBlockListExport {
        pages
            .sorted { $0.index < $1.index }
            .map { page in
                page.regions
                    .sorted { $0.index < $1.index }
                    .map { region in
                        OCRBlockListItem(
                            index: region.index,
                            label: canonicalLabel(for: region.kind),
                            content: region.content ?? "",
                            bbox2d: [region.bbox.x1, region.bbox.y1, region.bbox.x2, region.bbox.y2]
                        )
                    }
            }
    }
}

private func canonicalLabel(for kind: OCRRegionKind) -> String {
    switch kind {
    case .image:
        "image"
    default:
        // The canonical examples schema only distinguishes `text` vs `image`.
        "text"
    }
}
