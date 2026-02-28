@testable import DocLayoutAdapter
import VLMRuntimeKit
import XCTest

final class PPDocLayoutV3BBoxConversionTests: XCTestCase {
    func testToNormalizedBBox_usesTruncationForAllEdges() throws {
        struct Fixture: Sendable {
            var x1: Float
            var y1: Float
            var x2: Float
            var y2: Float
            var expected: OCRNormalizedBBox
        }

        let fixtures: [Fixture] = [
            // Values just below an integer boundary must not round up on the max edge.
            .init(
                x1: 0.0,
                y1: 0.0,
                x2: 0.431_999_9,
                y2: 0.999_999_9,
                expected: .init(x1: 0, y1: 0, x2: 431, y2: 999)
            ),
            // Exact boundaries should map cleanly.
            .init(
                x1: 0.211,
                y1: 0.667,
                x2: 0.432,
                y2: 1.0,
                expected: .init(x1: 211, y1: 667, x2: 432, y2: 1000)
            ),
            // Clamp out-of-range inputs before conversion.
            .init(
                x1: -0.5,
                y1: -0.1,
                x2: 1.2,
                y2: 2.0,
                expected: .init(x1: 0, y1: 0, x2: 1000, y2: 1000)
            ),
        ]

        for fixture in fixtures {
            let bbox = PPDocLayoutV3BBoxConversion.toNormalizedBBox(
                x1: fixture.x1,
                y1: fixture.y1,
                x2: fixture.x2,
                y2: fixture.y2
            )
            XCTAssertEqual(bbox, fixture.expected)
        }
    }
}
