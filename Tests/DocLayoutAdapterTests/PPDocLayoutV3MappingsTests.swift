import DocLayoutAdapter
import VLMRuntimeKit
import XCTest

final class PPDocLayoutV3MappingsTests: XCTestCase {
    func testLabelTaskMapping_containsExpectedLabels() {
        XCTAssertEqual(PPDocLayoutV3Mappings.labelTaskMapping["doc_title"], .text)
        XCTAssertEqual(PPDocLayoutV3Mappings.labelTaskMapping["table"], .table)
        XCTAssertEqual(PPDocLayoutV3Mappings.labelTaskMapping["display_formula"], .formula)
        XCTAssertEqual(PPDocLayoutV3Mappings.labelTaskMapping["formula"], .formula)
        XCTAssertEqual(PPDocLayoutV3Mappings.labelTaskMapping["image"], .skip)
        XCTAssertEqual(PPDocLayoutV3Mappings.labelTaskMapping["header"], .abandon)
    }

    func testLabelToVisualizationKind_containsExpectedLabels() {
        XCTAssertEqual(PPDocLayoutV3Mappings.labelToVisualizationKind["doc_title"], .text)
        XCTAssertEqual(PPDocLayoutV3Mappings.labelToVisualizationKind["table"], .table)
        XCTAssertEqual(PPDocLayoutV3Mappings.labelToVisualizationKind["display_formula"], .formula)
        XCTAssertEqual(PPDocLayoutV3Mappings.labelToVisualizationKind["formula"], .formula)
        XCTAssertEqual(PPDocLayoutV3Mappings.labelToVisualizationKind["image"], .image)
    }

    func testVisualizationMappingIsSubsetOfTaskMapping() {
        for label in PPDocLayoutV3Mappings.labelToVisualizationKind.keys {
            XCTAssertNotNil(
                PPDocLayoutV3Mappings.labelTaskMapping[label], "Missing labelTaskMapping entry for '\(label)'")
        }
    }
}
