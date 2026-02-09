@testable import VLMRuntimeKit
import XCTest

final class PromptTemplateTests: XCTestCase {
    func testSplitByImagePlaceholder() throws {
        let t = PromptTemplate()
        let (p, s) = try t.splitByImagePlaceholder("<image> hello")
        XCTAssertEqual(p, "")
        XCTAssertEqual(s, " hello")
    }

    func testMissingPlaceholderThrows() {
        let t = PromptTemplate(imagePlaceholder: "<image>")
        XCTAssertThrowsError(try t.splitByImagePlaceholder("no placeholder"))
    }

    func testInstructionStructuredJSONIncludesSchema() {
        let t = PromptTemplate()
        let schema = "{ \"type\": \"object\" }"
        let text = t.instruction(for: .structuredJSON(schema: schema))
        XCTAssertTrue(text.contains(schema))
    }
}
