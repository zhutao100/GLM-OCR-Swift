import Foundation
@testable import GLMOCRAdapter
import MLX
import XCTest

private enum GLMOCRTestEnv {
    static var modelFolderURL: URL? {
        guard let value = ProcessInfo.processInfo.environment["GLMOCR_TEST_MODEL_FOLDER"], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
    }

    static var runForwardPass: Bool {
        ProcessInfo.processInfo.environment["GLMOCR_TEST_RUN_FORWARD_PASS"] == "1"
    }
}

final class GLMOCRTokenizerIntegrationTests: XCTestCase {
    func testSpecialTokenIDs_matchSnapshot() async throws {
        guard let modelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_TEST_MODEL_FOLDER to a local HF snapshot folder to enable this test.")
        }

        let config = try GLMOCRConfig.load(from: modelFolder)
        let tokenizer = try await GLMOCRTokenizer.load(from: modelFolder, config: config)
        let ids = tokenizer.specialTokenIDs

        XCTAssertEqual(ids.eosId, tokenizer.tokenizer.eosTokenId)
        XCTAssertEqual(ids.padId, config.textConfig.padTokenId)

        XCTAssertEqual(ids.gMaskId, 59248)
        XCTAssertEqual(ids.sopId, 59250)
        XCTAssertEqual(ids.systemId, 59252)
        XCTAssertEqual(ids.userId, 59253)
        XCTAssertEqual(ids.assistantId, 59254)

        XCTAssertEqual(ids.beginImageId, 59256)
        XCTAssertEqual(ids.endImageId, 59257)
        XCTAssertEqual(ids.imageId, 59280)

        XCTAssertEqual(ids.beginImageId, config.imageStartTokenId)
        XCTAssertEqual(ids.endImageId, config.imageEndTokenId)
        XCTAssertEqual(ids.imageId, config.imageTokenId)
    }
}

final class GLMOCRForwardPassIntegrationTests: XCTestCase {
    func testForwardPassGoldenTop5() async throws {
        guard GLMOCRTestEnv.runForwardPass else {
            throw XCTSkip("Set GLMOCR_TEST_RUN_FORWARD_PASS=1 to enable this integration test.")
        }
        guard let modelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_TEST_MODEL_FOLDER to a local HF snapshot folder to enable this test.")
        }

        try ensureMLXMetalLibraryColocated()

        let config = try GLMOCRConfig.load(from: modelFolder)
        let tokenizer = try await GLMOCRTokenizer.load(from: modelFolder, config: config)
        let ids = tokenizer.specialTokenIDs

        let imageSize = config.visionConfig.imageSize ?? 336
        let patchSize = config.visionConfig.patchSize ?? 14
        let temporalPatchSize = config.visionConfig.temporalPatchSize ?? 2
        let mergeSize = config.visionConfig.spatialMergeSize ?? 2

        let grid = imageSize / patchSize
        let downGrid = grid / mergeSize
        let numImageTokens = downGrid * downGrid

        MLXRandom.seed(0)
        let pixelValues = MLXRandom.normal([1, temporalPatchSize, imageSize, imageSize, 3]).asType(.bfloat16)

        let promptTokenIDs = tokenizer.tokenizer.encode(text: " OCR:", addSpecialTokens: false)
        var inputIds: [Int] = [ids.gMaskId, ids.sopId, ids.userId, ids.beginImageId]
        inputIds.append(contentsOf: Array(repeating: ids.imageId, count: numImageTokens))
        inputIds.append(ids.endImageId)
        inputIds.append(contentsOf: promptTokenIDs)

        let expectedSeqLen = inputIds.count
        let inputIdArray = MLXArray(inputIds.map { Int32($0) }).reshaped(1, -1)

        let model = try await GLMOCRModel.load(from: modelFolder)
        let logits = try model.forward(inputIds: inputIdArray, pixelValues: pixelValues)
        try checkedEval(logits)

        XCTAssertEqual(logits.shape, [1, expectedSeqLen, config.textConfig.vocabSize ?? 59392])

        let last = logits[0, -1].asType(.float32).asArray(Float.self)
        let top = topK(last, k: 5)

        XCTAssertEqual(top.map(\.id), [25165, 4818, 18521, 49812, 27506])

        let expected: [Float] = [10.0625, 9.5625, 9.5, 9.4375, 9.0]
        for (i, pair) in top.enumerated() {
            XCTAssertEqual(pair.logit, expected[i], accuracy: 0.25)
        }
    }

    private struct TopPair: Sendable {
        let id: Int
        let logit: Float
    }

    private func topK(_ values: [Float], k: Int) -> [TopPair] {
        precondition(k > 0)
        return values.indices
            .sorted { values[$0] > values[$1] }
            .prefix(k)
            .map { TopPair(id: $0, logit: values[$0]) }
    }

    private func ensureMLXMetalLibraryColocated() throws {
        guard let executableURL = Bundle(for: Self.self).executableURL else {
            throw XCTSkip("Cannot determine test executable location for colocating mlx.metallib.")
        }

        let binaryDir = executableURL.deletingLastPathComponent()
        let colocated = binaryDir.appendingPathComponent("mlx.metallib")
        if FileManager.default.fileExists(atPath: colocated.path) { return }

        // Expected layout for SwiftPM:
        //   <bin>/GLMOCRSwiftPackageTests.xctest/Contents/MacOS/GLMOCRSwiftPackageTests
        // and scripts/build_mlx_metallib.sh writes:
        //   <bin>/mlx.metallib
        let binRoot = binaryDir
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // *.xctest
            .deletingLastPathComponent() // <bin>
        let built = binRoot.appendingPathComponent("mlx.metallib")
        guard FileManager.default.fileExists(atPath: built.path) else {
            throw XCTSkip("mlx.metallib not found at \(built.path). Run scripts/build_mlx_metallib.sh first.")
        }

        _ = try? FileManager.default.removeItem(at: colocated)
        try FileManager.default.copyItem(at: built, to: colocated)
    }
}
