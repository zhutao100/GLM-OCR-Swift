import Foundation

/// A bounding box in the official normalized coordinate space `[0, 1000]`,
/// with the origin at the **top-left** of the image.
///
/// - Important: Callers are expected to keep the invariant:
///   `0...1000` for each component and `x1 < x2`, `y1 < y2`.
public struct OCRNormalizedBBox: Sendable, Codable, Equatable {
    public var x1: Int
    public var y1: Int
    public var x2: Int
    public var y2: Int

    public init(x1: Int, y1: Int, x2: Int, y2: Int) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

/// A point in the official normalized coordinate space `[0, 1000]`,
/// with the origin at the **top-left** of the image.
public struct OCRNormalizedPoint: Sendable, Codable, Equatable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public enum OCRRegionKind: String, Sendable, Codable {
    case text
    case table
    case formula
    case image
    case unknown
}

public struct OCRRegion: Sendable, Codable, Equatable {
    /// 0-based reading order within the page.
    public var index: Int
    public var kind: OCRRegionKind
    /// Model/native label (e.g. `doc_title`, `table`, `image`).
    public var nativeLabel: String
    public var bbox: OCRNormalizedBBox
    public var polygon: [OCRNormalizedPoint]?
    /// Region content. `nil` for skipped regions (e.g. images).
    public var content: String?

    public init(
        index: Int,
        kind: OCRRegionKind,
        nativeLabel: String,
        bbox: OCRNormalizedBBox,
        polygon: [OCRNormalizedPoint]? = nil,
        content: String? = nil
    ) {
        self.index = index
        self.kind = kind
        self.nativeLabel = nativeLabel
        self.bbox = bbox
        self.polygon = polygon
        self.content = content
    }
}

public struct OCRPage: Sendable, Codable, Equatable {
    /// 0-based page index within the document.
    public var index: Int
    public var regions: [OCRRegion]

    public init(index: Int, regions: [OCRRegion]) {
        self.index = index
        self.regions = regions
    }
}

public struct OCRDocument: Sendable, Codable, Equatable {
    public var pages: [OCRPage]

    public init(pages: [OCRPage]) {
        self.pages = pages
    }
}
