import Foundation
import VLMRuntimeKit
import XCTest

final class OCRBlockListExportStableJSONTests: XCTestCase {
    func testBlockListExportJSON_hasStableKeyOrder() throws {
        let document = OCRDocument(pages: [
            OCRPage(
                index: 0,
                regions: [
                    OCRRegion(
                        index: 0,
                        kind: .text,
                        nativeLabel: "doc_text",
                        bbox: OCRNormalizedBBox(x1: 10, y1: 20, x2: 30, y2: 40),
                        content: "hello"
                    )
                ]
            )
        ])

        let data = try document.toBlockListExportJSON()
        let json = String(decoding: data, as: UTF8.self)

        guard
            let indexRange = json.range(of: "\"index\""),
            let labelRange = json.range(of: "\"label\""),
            let contentRange = json.range(of: "\"content\""),
            let bboxRange = json.range(of: "\"bbox_2d\"")
        else {
            XCTFail("Expected block-list JSON keys not found in output:\n\(json)")
            return
        }

        XCTAssertLessThan(indexRange.lowerBound, labelRange.lowerBound)
        XCTAssertLessThan(labelRange.lowerBound, contentRange.lowerBound)
        XCTAssertLessThan(contentRange.lowerBound, bboxRange.lowerBound)
    }
}
