import Foundation
import MLX
import VLMRuntimeKit
import XCTest

@testable import GLMOCRAdapter

final class GLMOCRGenerateIntegrationTests: XCTestCase {
    func testGenerateOneToken_smoke() async throws {
        guard GLMOCRTestEnv.runGenerate else {
            throw XCTSkip("Set GLMOCR_TEST_RUN_GENERATE=1 to enable this integration test.")
        }
        guard let modelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_SNAPSHOT_PATH to a local HF snapshot folder to enable this test.")
        }

        try ensureMLXMetalLibraryColocated(for: Self.self)

        let config = try GLMOCRConfig.load(from: modelFolder)

        let imageSize = config.visionConfig.imageSize ?? 336
        let temporalPatchSize = config.visionConfig.temporalPatchSize ?? 2

        MLXRandom.seed(0)
        let pixelValues = MLXRandom.normal([1, temporalPatchSize, imageSize, imageSize, 3]).asType(.bfloat16)

        let model = try await GLMOCRModel.load(from: modelFolder)
        let prompt = GLMOCRProcessor().makePrompt(for: .text)
        let options = GenerateOptions(maxNewTokens: 1, temperature: 0, topP: 1)

        let result = try await model.generate(prompt: prompt, pixelValues: pixelValues, options: options)
        XCTAssertLessThanOrEqual(result.tokenIDs?.count ?? 0, 1)
    }
}
