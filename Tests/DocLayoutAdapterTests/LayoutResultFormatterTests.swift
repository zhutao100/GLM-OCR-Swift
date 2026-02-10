import DocLayoutAdapter
import VLMRuntimeKit
import XCTest

final class LayoutResultFormatterTests: XCTestCase {
    func testTitleFormatting_docTitleAndParagraphTitle() {
        let pages = [
            OCRPage(
                index: 0,
                regions: [
                    OCRRegion(
                        index: 1,
                        kind: .unknown,
                        nativeLabel: "paragraph_title",
                        bbox: OCRNormalizedBBox(x1: 0, y1: 20, x2: 1000, y2: 40),
                        content: "- Section Title"
                    ),
                    OCRRegion(
                        index: 0,
                        kind: .unknown,
                        nativeLabel: "doc_title",
                        bbox: OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 20),
                        content: "## Document Title"
                    ),
                    OCRRegion(
                        index: 2,
                        kind: .unknown,
                        nativeLabel: "text",
                        bbox: OCRNormalizedBBox(x1: 0, y1: 40, x2: 1000, y2: 60),
                        content: "Hello\nWorld"
                    ),
                ]
            ),
        ]

        let (document, markdown) = LayoutResultFormatter.format(pages: pages)

        XCTAssertEqual(markdown, "# Document Title\n\n## Section Title\n\nHello\n\nWorld")

        XCTAssertEqual(document.pages.count, 1)
        XCTAssertEqual(document.pages[0].regions.map(\.index), [0, 1, 2])
        XCTAssertEqual(document.pages[0].regions.map(\.content), ["# Document Title", "## Section Title", "Hello\n\nWorld"])
        XCTAssertEqual(document.pages[0].regions.map(\.kind), [.text, .text, .text])
    }

    func testFormulaWrappingAndFormulaNumberMerge() {
        let pages = [
            OCRPage(
                index: 0,
                regions: [
                    OCRRegion(
                        index: 0,
                        kind: .unknown,
                        nativeLabel: "display_formula",
                        bbox: OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 300),
                        content: "E = mc^2"
                    ),
                    OCRRegion(
                        index: 1,
                        kind: .unknown,
                        nativeLabel: "formula_number",
                        bbox: OCRNormalizedBBox(x1: 900, y1: 280, x2: 1000, y2: 300),
                        content: "(1)"
                    ),
                ]
            ),
        ]

        let (document, markdown) = LayoutResultFormatter.format(pages: pages)

        XCTAssertEqual(markdown, "$$\nE = mc^2 \\tag{1}\n$$")
        XCTAssertEqual(document.pages[0].regions.count, 1)
        XCTAssertEqual(document.pages[0].regions[0].kind, .formula)
        XCTAssertEqual(document.pages[0].regions[0].nativeLabel, "display_formula")
        XCTAssertEqual(document.pages[0].regions[0].content, "$$\nE = mc^2 \\tag{1}\n$$")
    }

    func testHyphenatedTextMerge() {
        let pages = [
            OCRPage(
                index: 0,
                regions: [
                    OCRRegion(
                        index: 0,
                        kind: .unknown,
                        nativeLabel: "text",
                        bbox: OCRNormalizedBBox(x1: 0, y1: 0, x2: 500, y2: 50),
                        content: "inter-"
                    ),
                    OCRRegion(
                        index: 1,
                        kind: .unknown,
                        nativeLabel: "text",
                        bbox: OCRNormalizedBBox(x1: 0, y1: 60, x2: 500, y2: 110),
                        content: "national"
                    ),
                ]
            ),
        ]

        let (document, markdown) = LayoutResultFormatter.format(pages: pages)

        XCTAssertEqual(markdown, "international")
        XCTAssertEqual(document.pages[0].regions.count, 1)
        XCTAssertEqual(document.pages[0].regions[0].content, "international")
    }

    func testImagePlaceholderEmission() {
        let pages = [
            OCRPage(
                index: 2,
                regions: [
                    OCRRegion(
                        index: 0,
                        kind: .unknown,
                        nativeLabel: "image",
                        bbox: OCRNormalizedBBox(x1: 10, y1: 20, x2: 30, y2: 40),
                        content: nil
                    ),
                ]
            ),
        ]

        let (_, markdown) = LayoutResultFormatter.format(pages: pages)
        XCTAssertEqual(markdown, "![](page=2,bbox=[10,20,30,40])")
    }
}
