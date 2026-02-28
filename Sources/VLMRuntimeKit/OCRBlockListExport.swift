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

    fileprivate enum CodingKeys: String, CodingKey {
        case index
        case label
        case content
        case bbox2d = "bbox_2d"
    }
}

public typealias OCRBlockListExport = [[OCRBlockListItem]]

extension OCRDocument {
    /// Convert to the block-list schema used by the reference `examples/reference_result/*/*.json`.
    public func toBlockListExport() -> OCRBlockListExport {
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

    /// Encode the examples-compatible block-list JSON with a deterministic key order:
    /// `index`, `label`, `content`, `bbox_2d`.
    public func toBlockListExportJSON(prettyPrinted: Bool = true, withoutEscapingSlashes: Bool = true) throws -> Data {
        let export = toBlockListExport()

        let orderedKeys = OCRBlockListItem.canonicalKeyOrder.map(\.stringValue)
        let prefixPairs = orderedKeys.enumerated().map { (idx, key) in (original: key, prefixed: "\(idx)_\(key)") }
        let prefixedByOriginal = Dictionary(uniqueKeysWithValues: prefixPairs.map { ($0.original, $0.prefixed) })

        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted {
            formatting.insert(.prettyPrinted)
        }
        if withoutEscapingSlashes {
            formatting.insert(.withoutEscapingSlashes)
        }
        encoder.outputFormatting = formatting

        encoder.keyEncodingStrategy = .custom { codingPath in
            guard let last = codingPath.last else { return _StablePrefixedCodingKey.empty }
            guard let prefixed = prefixedByOriginal[last.stringValue] else { return last }
            return _StablePrefixedCodingKey(stringValue: prefixed) ?? last
        }

        var json = String(decoding: try encoder.encode(export), as: UTF8.self)
        for pair in prefixPairs {
            json = json.replacingOccurrences(of: "\"\(pair.prefixed)\"", with: "\"\(pair.original)\"")
        }
        return Data(json.utf8)
    }
}

private func canonicalLabel(for kind: OCRRegionKind) -> String {
    switch kind {
    case .image:
        "image"
    case .table:
        "table"
    case .formula:
        "formula"
    default:
        "text"
    }
}

extension OCRBlockListItem {
    fileprivate static let canonicalKeyOrder: [CodingKeys] = [.index, .label, .content, .bbox2d]
}

private struct _StablePrefixedCodingKey: CodingKey {
    static let empty = _StablePrefixedCodingKey(stringValue: "")!

    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}
