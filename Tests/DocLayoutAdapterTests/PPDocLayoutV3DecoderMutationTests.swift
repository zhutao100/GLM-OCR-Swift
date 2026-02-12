@testable import DocLayoutAdapter
import Foundation
import MLX
import XCTest

final class PPDocLayoutV3DecoderMutationTests: XCTestCase {
    func testMultiscaleDeformableAttention_doesNotMutateHiddenStatesWhenAddingPositionEmbeddings() throws {
        try ensureMLXMetalLibraryColocated(for: Self.self)

        let configData = Data(
            """
            {
              "d_model": 8,
              "num_queries": 2,
              "num_feature_levels": 1,
              "decoder_attention_heads": 2,
              "decoder_n_points": 2
            }
            """.utf8
        )
        let modelConfig = try JSONDecoder().decode(PPDocLayoutV3ModelConfig.self, from: configData)
        let attention = PPDocLayoutV3MultiscaleDeformableAttentionCore(modelConfig: modelConfig)

        let hiddenStates = MLXArray((0 ..< 16).map { Float($0) / 10 }).reshaped(1, 2, 8)
        let positionEmbeddings = MLXArray((0 ..< 16).map { Float($0) / 100 }).reshaped(1, 2, 8)

        let encoderHiddenStates = MLXArray((0 ..< 32).map { Float($0) / 20 }).reshaped(1, 4, 8)
        let referencePoints = MLXArray([Float](repeating: 0.5, count: 1 * 2 * 1 * 4)).reshaped(1, 2, 1, 4)
        let spatialShapes = MLXArray([Int32(2), Int32(2)]).reshaped(1, 2)

        let before = hiddenStates.asArray(Float.self)

        let output = attention.forward(
            hiddenStates: hiddenStates,
            encoderHiddenStates: encoderHiddenStates,
            positionEmbeddings: positionEmbeddings,
            referencePoints: referencePoints,
            spatialShapes: spatialShapes,
            spatialShapesList: [(height: 2, width: 2)]
        )
        _ = output.asArray(Float.self)

        let after = hiddenStates.asArray(Float.self)
        XCTAssertEqual(after, before)
    }
}
