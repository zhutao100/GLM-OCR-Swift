import XCTest

@testable import VLMRuntimeKit

final class GenerateOptionsPresetTests: XCTestCase {
    func testInit_defaultsToDefaultGreedyPreset() {
        let options = GenerateOptions()

        XCTAssertEqual(options.preset, .defaultGreedyV1)
        XCTAssertEqual(options.temperature, 0)
        XCTAssertEqual(options.topP, 1)
    }

    func testPresetFactory_buildsDefaultGreedyPresetOptions() {
        let options = GenerateOptions.preset(.defaultGreedyV1, maxNewTokens: 256)

        XCTAssertEqual(options.maxNewTokens, 256)
        XCTAssertEqual(options.preset, .defaultGreedyV1)
        XCTAssertEqual(options.temperature, 0)
        XCTAssertEqual(options.topP, 1)
    }

    func testPresetFactory_buildsParityGreedyPresetOptions() {
        let options = GenerateOptions.preset(.parityGreedyV1, maxNewTokens: 512)

        XCTAssertEqual(options.maxNewTokens, 512)
        XCTAssertEqual(options.preset, .parityGreedyV1)
        XCTAssertEqual(options.temperature, 0)
        XCTAssertEqual(options.topP, 1)
    }
}
