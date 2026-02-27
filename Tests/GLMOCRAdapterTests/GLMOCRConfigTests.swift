import XCTest

@testable import GLMOCRAdapter

final class GLMOCRConfigTests: XCTestCase {
    func testDecodeSnakeCaseFields() throws {
        let json = """
            {
              "model_type": "glm_ocr",
              "text_config": {
                "hidden_size": 1536,
                "num_attention_heads": 16,
                "num_key_value_heads": 8,
                "head_dim": 128,
                "vocab_size": 59392,
                "pad_token_id": 59246,
                "eos_token_id": [59246, 59253],
                "rms_norm_eps": 1e-5
              },
              "vision_config": {
                "hidden_size": 1024,
                "depth": 24,
                "num_heads": 16,
                "intermediate_size": 4096,
                "image_size": 336,
                "patch_size": 14,
                "temporal_patch_size": 2,
                "spatial_merge_size": 2,
                "out_hidden_size": 1536,
                "rms_norm_eps": 1e-5
              },
              "image_start_token_id": 59256,
              "image_token_id": 59280,
              "image_end_token_id": 59257
            }
            """

        let config = try JSONDecoder().decode(GLMOCRConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.modelType, "glm_ocr")
        XCTAssertEqual(config.textConfig.hiddenSize, 1536)
        XCTAssertEqual(config.textConfig.numAttentionHeads, 16)
        XCTAssertEqual(config.textConfig.numKeyValueHeads, 8)
        XCTAssertEqual(config.textConfig.headDim, 128)
        XCTAssertEqual(config.visionConfig.hiddenSize, 1024)
        XCTAssertEqual(config.visionConfig.imageSize, 336)
        XCTAssertEqual(config.imageStartTokenId, 59256)
        XCTAssertEqual(config.imageTokenId, 59280)
        XCTAssertEqual(config.imageEndTokenId, 59257)
    }
}
