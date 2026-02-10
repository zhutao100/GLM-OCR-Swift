import Foundation
import VLMRuntimeKit
import XCTest

final class OCRResultCodableTests: XCTestCase {
    func testOCRResult_codableRoundTrip_withStructuredDocument() throws {
        let document = OCRDocument(pages: [
            OCRPage(index: 0, regions: [
                OCRRegion(
                    index: 0,
                    kind: .text,
                    nativeLabel: "doc_text",
                    bbox: OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000),
                    polygon: [
                        .init(x: 0, y: 0),
                        .init(x: 1000, y: 0),
                        .init(x: 1000, y: 1000),
                        .init(x: 0, y: 1000),
                    ],
                    content: "hello"
                ),
            ]),
        ])

        let result = OCRResult(
            text: "md",
            rawTokens: [1, 2, 3],
            document: document,
            diagnostics: Diagnostics(
                modelID: "model",
                revision: "rev",
                timings: ["recognize": 1.23],
                notes: ["note"]
            )
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(OCRResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }
}
