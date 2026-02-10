import DocLayoutAdapter
import Foundation
import XCTest

final class PPDocLayoutV3ConfigTests: XCTestCase {
    func testDecodeMinimalConfig_fixtureDecodesRequiredFields() throws {
        let data = try fixtureData(name: "ppdoclayoutv3_config_minimal")
        let config = try JSONDecoder().decode(PPDocLayoutV3Config.self, from: data)

        XCTAssertEqual(config.modelType, "ppdoclayoutv3")
        XCTAssertEqual(config.numLabels, 25)
        XCTAssertEqual(config.id2label[0], "abstract")
        XCTAssertEqual(config.id2label[21], "table")
        XCTAssertEqual(config.label2id?["table"], 21)
    }

    private func fixtureData(name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            XCTFail("Missing fixture: \(name).json", file: file, line: line)
            return Data()
        }
        return try Data(contentsOf: url)
    }
}
