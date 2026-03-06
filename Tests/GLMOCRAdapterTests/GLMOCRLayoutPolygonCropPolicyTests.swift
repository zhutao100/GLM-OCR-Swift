import DocLayoutAdapter
import XCTest

@testable import GLMOCRAdapter

final class GLMOCRLayoutPolygonCropPolicyTests: XCTestCase {
    func testShouldUsePolygonCropForOCR_usesPolygonForTables() {
        XCTAssertTrue(shouldUsePolygonCropForOCR(taskType: LayoutTaskType.table))
    }

    func testShouldUsePolygonCropForOCR_usesBBoxForFormulaAndText() {
        XCTAssertFalse(shouldUsePolygonCropForOCR(taskType: LayoutTaskType.formula))
        XCTAssertFalse(shouldUsePolygonCropForOCR(taskType: LayoutTaskType.text))
    }
}
