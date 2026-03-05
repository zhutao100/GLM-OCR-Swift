import Foundation
import XCTest

import VLMRuntimeKit

@testable import GLMOCRAdapter

final class GLMOCRChatTemplateConformanceTests: XCTestCase {
    func testBuildInputIDs_matchesTokenizerEncoding_singleTurn() async throws {
        guard let modelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_SNAPSHOT_PATH to a local HF snapshot folder to enable this test.")
        }

        let config = try GLMOCRConfig.load(from: modelFolder)
        let tokenizer = try await GLMOCRTokenizer.load(from: modelFolder, config: config)

        let imageSize = config.visionConfig.imageSize ?? 336
        let patchSize = config.visionConfig.patchSize ?? 14
        let mergeSize = config.visionConfig.spatialMergeSize ?? 2
        let grid = imageSize / patchSize
        let downGrid = grid / mergeSize
        let numImageTokens = downGrid * downGrid

        let prompt = GLMOCRProcessor().makePrompt(for: .text)
        let template = GLMOCRChatTemplate(imagePlaceholder: "<image>", appendNoThink: true)
        let inputIds = try template.buildInputIDs(prompt: prompt, tokenizer: tokenizer, numImageTokens: numImageTokens)

        let splitter = PromptTemplate(imagePlaceholder: "<image>")
        let (prefix, suffix) = try splitter.splitByImagePlaceholder(prompt)

        let imageTokens = String(repeating: "<|image|>", count: numImageTokens)
        let rendered =
            "[gMASK]<sop>\n"
            + "<|user|>\n"
            + prefix
            + "<|begin_of_image|>"
            + imageTokens
            + "<|end_of_image|>"
            + suffix
            + "\n/nothink"
            + "\n<|assistant|>\n"

        let expected = tokenizer.tokenizer.encode(text: rendered, addSpecialTokens: false)
        XCTAssertEqual(expected, inputIds)
    }

    func testChatTemplateSnapshot_containsExpectedMarkers_whenPresent() throws {
        guard let modelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_SNAPSHOT_PATH to a local HF snapshot folder to enable this test.")
        }

        let url = modelFolder.appendingPathComponent("chat_template.jinja")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("chat_template.jinja not found in snapshot at \(url.path).")
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("[gMASK]"))
        XCTAssertTrue(contents.contains("<sop>"))
        XCTAssertTrue(contents.contains("<|user|>"))
        XCTAssertTrue(contents.contains("<|assistant|>"))
        XCTAssertTrue(contents.contains("/nothink") || contents.contains("enable_thinking"))
    }
}
