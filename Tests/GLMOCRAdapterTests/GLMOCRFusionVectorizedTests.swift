import MLX
import XCTest

@testable import GLMOCRAdapter

final class GLMOCRFusionVectorizedTests: MLXTestCase {
    func testFuse_vectorizedMatchesNaiveReference_multiBatch() throws {
        let imageTokenId = 999
        let batch = 2
        let seqLen = 6
        let hidden = 4
        let n = 3

        let inputIds: [Int32] = [
            101, 999, 102, 999, 999, 103,
            999, 201, 999, 202, 203, 999,
        ]

        let textValues = (0..<(batch * seqLen * hidden)).map { Float($0) }
        let visionValues: [Float] = [
            10, 11, 12, 13, 20, 21, 22, 23, 30, 31, 32, 33,
            110, 111, 112, 113, 120, 121, 122, 123, 130, 131, 132, 133,
        ]

        let inputIdArray = MLXArray(inputIds).reshaped(batch, seqLen)
        let textEmbeddings = MLXArray(textValues).reshaped(batch, seqLen, hidden)
        let visionEmbeddings = MLXArray(visionValues).reshaped(batch, n, hidden)

        let fused = try GLMOCRFusion.fuse(
            inputIds: inputIdArray,
            textEmbeddings: textEmbeddings,
            visionEmbeddings: visionEmbeddings,
            imageTokenId: imageTokenId
        )
        let fusedValues = fused.asType(.float32).asArray(Float.self)
        let expected = try naiveFuse(
            inputIds: inputIds,
            textValues: textValues,
            visionValues: visionValues,
            batch: batch,
            seqLen: seqLen,
            hidden: hidden,
            visionTokenCount: n,
            imageTokenId: Int32(imageTokenId)
        )

        XCTAssertEqual(fusedValues, expected)
    }

    func testFuse_throwsOnMismatchCounts() throws {
        let imageTokenId = 999
        let batch = 1
        let seqLen = 6
        let hidden = 4
        let n = 3

        let inputIds: [Int32] = [
            101, 999, 102, 999, 103, 104,
        ]

        let textValues = (0..<(batch * seqLen * hidden)).map { Float($0) }
        let visionValues = (0..<(batch * n * hidden)).map { Float($0 + 1000) }

        let inputIdArray = MLXArray(inputIds).reshaped(batch, seqLen)
        let textEmbeddings = MLXArray(textValues).reshaped(batch, seqLen, hidden)
        let visionEmbeddings = MLXArray(visionValues).reshaped(batch, n, hidden)

        XCTAssertThrowsError(
            try GLMOCRFusion.fuse(
                inputIds: inputIdArray,
                textEmbeddings: textEmbeddings,
                visionEmbeddings: visionEmbeddings,
                imageTokenId: imageTokenId
            )
        ) { error in
            XCTAssertEqual(error as? GLMOCRFusionError, .imageTokenCountMismatch(expected: 3, actual: 2))
        }
    }

    private func naiveFuse(
        inputIds: [Int32],
        textValues: [Float],
        visionValues: [Float],
        batch: Int,
        seqLen: Int,
        hidden: Int,
        visionTokenCount: Int,
        imageTokenId: Int32
    ) throws -> [Float] {
        var out = textValues
        for b in 0..<batch {
            var visionIndex = 0
            for s in 0..<seqLen where inputIds[b * seqLen + s] == imageTokenId {
                let outBase = (b * seqLen + s) * hidden
                let visionBase = (b * visionTokenCount + visionIndex) * hidden
                for h in 0..<hidden {
                    out[outBase + h] = visionValues[visionBase + h]
                }
                visionIndex += 1
            }

            guard visionIndex > 0 else {
                throw GLMOCRFusionError.missingImageToken(tokenID: Int(imageTokenId))
            }
            guard visionIndex == visionTokenCount else {
                throw GLMOCRFusionError.imageTokenCountMismatch(expected: visionTokenCount, actual: visionIndex)
            }
        }
        return out
    }
}
