import Foundation
@testable import GLMOCRAdapter
import XCTest

final class GLMOCRChatTemplateIntegrationTests: XCTestCase {
    func testBuildInputIDs_insertsExpectedImageTokenCount() async throws {
        guard let modelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_TEST_MODEL_FOLDER to a local HF snapshot folder to enable this test.")
        }

        let config = try GLMOCRConfig.load(from: modelFolder)
        let tokenizer = try await GLMOCRTokenizer.load(from: modelFolder, config: config)
        let ids = tokenizer.specialTokenIDs

        let imageSize = config.visionConfig.imageSize ?? 336
        let patchSize = config.visionConfig.patchSize ?? 14
        let mergeSize = config.visionConfig.spatialMergeSize ?? 2
        let grid = imageSize / patchSize
        let downGrid = grid / mergeSize
        let numImageTokens = downGrid * downGrid

        let prompt = GLMOCRProcessor().makePrompt(for: .text)
        let template = GLMOCRChatTemplate(imagePlaceholder: "<image>", appendNoThink: true)
        let inputIds = try template.buildInputIDs(prompt: prompt, tokenizer: tokenizer, numImageTokens: numImageTokens)

        XCTAssertEqual(inputIds.first, ids.gMaskId)
        XCTAssertEqual(inputIds.dropFirst().first, ids.sopId)

        let imageTokenCount = inputIds.count(where: { $0 == ids.imageId })
        XCTAssertEqual(imageTokenCount, numImageTokens)
        XCTAssertEqual(inputIds.count(where: { $0 == ids.beginImageId }), 1)
        XCTAssertEqual(inputIds.count(where: { $0 == ids.endImageId }), 1)

        XCTAssertTrue(inputIds.contains(ids.userId))
        XCTAssertTrue(inputIds.contains(ids.assistantId))
    }
}
