@testable import GLMOCRAdapter
import XCTest

final class GLMOCRStopTokenPolicyTests: XCTestCase {
    func testStopTokenIDs_usesConfiguredEOS() throws {
        let json = """
        {
          "model_type": "glm_ocr",
          "text_config": {
            "pad_token_id": 59246,
            "eos_token_id": [59246, 59253]
          },
          "vision_config": {
            "hidden_size": 1024
          }
        }
        """

        let config = try JSONDecoder().decode(GLMOCRConfig.self, from: Data(json.utf8))
        let ids = GLMOCRSpecialTokenIDs(
            gMaskId: 0,
            sopId: 0,
            systemId: 0,
            userId: 59253,
            assistantId: 0,
            beginImageId: 0,
            imageId: 0,
            endImageId: 0,
            eosId: 59246,
            padId: 59246
        )

        XCTAssertEqual(GLMOCRModel.stopTokenIDs(config: config, ids: ids), [59246, 59253])
    }

    func testStopTokenIDs_includesTokenizerEOS_whenConfigHasDifferentStopIDs() throws {
        let json = """
        {
          "model_type": "glm_ocr",
          "text_config": {
            "pad_token_id": 59246,
            "eos_token_id": [59253]
          },
          "vision_config": {
            "hidden_size": 1024
          }
        }
        """

        let config = try JSONDecoder().decode(GLMOCRConfig.self, from: Data(json.utf8))
        let ids = GLMOCRSpecialTokenIDs(
            gMaskId: 0,
            sopId: 0,
            systemId: 0,
            userId: 59253,
            assistantId: 0,
            beginImageId: 0,
            imageId: 0,
            endImageId: 0,
            eosId: 59246,
            padId: 59246
        )

        XCTAssertEqual(GLMOCRModel.stopTokenIDs(config: config, ids: ids), [59246, 59253])
    }

    func testStopTokenIDs_fallsBackToTokenizerEOS_whenConfigMissingEOS() throws {
        let json = """
        {
          "model_type": "glm_ocr",
          "text_config": {
            "pad_token_id": 59246
          },
          "vision_config": {
            "hidden_size": 1024
          }
        }
        """

        let config = try JSONDecoder().decode(GLMOCRConfig.self, from: Data(json.utf8))
        let ids = GLMOCRSpecialTokenIDs(
            gMaskId: 0,
            sopId: 0,
            systemId: 0,
            userId: 0,
            assistantId: 0,
            beginImageId: 0,
            imageId: 0,
            endImageId: 0,
            eosId: 123,
            padId: 59246
        )

        XCTAssertEqual(GLMOCRModel.stopTokenIDs(config: config, ids: ids), [123])
    }
}
