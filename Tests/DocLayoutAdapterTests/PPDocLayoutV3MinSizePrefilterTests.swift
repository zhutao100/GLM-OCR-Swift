@testable import DocLayoutAdapter
import MLX
import XCTest

final class PPDocLayoutV3MinSizePrefilterTests: MLXTestCase {
    func testMaskLogitsForTinyBoxes_masksInvalidQueriesBeforeSelection() throws {
        // mask_h = mask_w = 200 -> min_norm = 1/200 = 0.005
        let logits = MLXArray([Float](arrayLiteral: 10, 9, 8, 1, 2, 3)).reshaped(1, 2, 3)
        let predBoxes = MLXArray(
            [Float](
                arrayLiteral:
                    0.5, 0.5, 0.005, 0.006,  // width == min_norm -> invalid (strict > in upstream)
                    0.5, 0.5, 0.006, 0.006  // valid
            )
        ).reshaped(1, 2, 4)

        let masked = PPDocLayoutV3Prefilters.maskLogitsForTinyBoxes(
            logits: logits,
            predBoxes: predBoxes,
            maskHeight: 200,
            maskWidth: 200
        )
        eval(masked)

        let values = masked.asArray(Float.self)
        XCTAssertEqual(values[0], -100.0)
        XCTAssertEqual(values[1], -100.0)
        XCTAssertEqual(values[2], -100.0)
        XCTAssertEqual(values[3], 1.0)
        XCTAssertEqual(values[4], 2.0)
        XCTAssertEqual(values[5], 3.0)
    }
}
