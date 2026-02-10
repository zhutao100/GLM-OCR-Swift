import DocLayoutAdapter
import XCTest

final class PPDocLayoutV3PreprocessorConfigTests: XCTestCase {
    func testDecodeMinimalConfig_fixtureDecodesRequiredFields() throws {
        guard let url = Bundle.module.url(forResource: "ppdoclayoutv3_preprocessor_config_minimal", withExtension: "json") else {
            XCTFail("Missing fixture ppdoclayoutv3_preprocessor_config_minimal.json")
            return
        }

        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(PPDocLayoutV3PreprocessorConfig.self, from: data)

        XCTAssertEqual(config.doResize, true)
        XCTAssertEqual(config.size?.height, 800)
        XCTAssertEqual(config.size?.width, 800)

        XCTAssertEqual(config.doRescale, true)
        XCTAssertEqual(config.rescaleFactor, 0.00392156862745098)

        XCTAssertEqual(config.doNormalize, true)
        XCTAssertEqual(config.imageMean ?? [], [0, 0, 0])
        XCTAssertEqual(config.imageStd ?? [], [1, 1, 1])
        XCTAssertEqual(config.resample, 3)

        let target = config.targetSize(originalWidth: 1234, originalHeight: 567)
        XCTAssertEqual(target?.width, 800)
        XCTAssertEqual(target?.height, 800)
    }
}
