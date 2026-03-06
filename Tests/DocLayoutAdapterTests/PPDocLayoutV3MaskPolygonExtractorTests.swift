import CoreGraphics
import VLMRuntimeKit
import XCTest

@testable import DocLayoutAdapter

final class PPDocLayoutV3MaskPolygonExtractorTests: XCTestCase {
    func testExtractPolygon_returnsNilForEmptyMask() {
        let mask = PPDocLayoutV3Mask(width: 4, height: 4, data: .init(repeating: 0, count: 16))

        let polygon = PPDocLayoutV3MaskPolygonExtractor.extractPolygon(
            bbox: OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000),
            mask: mask,
            imageSize: CGSize(width: 40, height: 40)
        )

        XCTAssertNil(polygon)
    }

    func testExtractPolygon_returnsNonRectangularPolygonForLShapedMask() {
        let mask = PPDocLayoutV3Mask(
            width: 8,
            height: 8,
            data: [
                1, 1, 1, 1, 0, 0, 0, 0,
                1, 1, 1, 1, 0, 0, 0, 0,
                1, 1, 1, 1, 0, 0, 0, 0,
                1, 1, 1, 1, 0, 0, 0, 0,
                1, 1, 0, 0, 0, 0, 0, 0,
                1, 1, 0, 0, 0, 0, 0, 0,
                1, 1, 0, 0, 0, 0, 0, 0,
                1, 1, 0, 0, 0, 0, 0, 0,
            ]
        )

        let polygon = PPDocLayoutV3MaskPolygonExtractor.extractPolygon(
            bbox: OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000),
            mask: mask,
            imageSize: CGSize(width: 80, height: 80)
        )

        XCTAssertNotNil(polygon)
        XCTAssertGreaterThan(polygon?.count ?? 0, 4)
        XCTAssertNotEqual(
            polygon,
            [
                OCRNormalizedPoint(x: 0, y: 0),
                OCRNormalizedPoint(x: 1000, y: 0),
                OCRNormalizedPoint(x: 1000, y: 1000),
                OCRNormalizedPoint(x: 0, y: 1000),
            ]
        )
    }
}
