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

    func testPreferredResizeBackendForRegionOCR_usesDeterministicForShortWideTextCrops() {
        XCTAssertEqual(
            preferredResizeBackendForRegionOCR(taskType: .text, cropPixelSize: (width: 351, height: 12)),
            .deterministicBicubicCPU
        )
    }

    func testPreferredResizeBackendForRegionOCR_keepsDefaultBackendForNarrowTextCrops() {
        XCTAssertNil(preferredResizeBackendForRegionOCR(taskType: .text, cropPixelSize: (width: 320, height: 34)))
    }

    func testPreferredResizeBackendForRegionOCR_keepsDefaultBackendForNonTextTasks() {
        XCTAssertNil(preferredResizeBackendForRegionOCR(taskType: .formula, cropPixelSize: (width: 351, height: 12)))
    }
}
