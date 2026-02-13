import CoreGraphics
import CoreImage
import Foundation
@testable import GLMOCRAdapter
import MLX
import XCTest

final class GLMOCRTokenizerIntegrationTests: XCTestCase {
    func testSpecialTokenIDs_matchSnapshot() async throws {
        guard let modelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_SNAPSHOT_PATH to a local HF snapshot folder to enable this test.")
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
    func testForwardPass_smoke() async throws {
        guard !GLMOCRTestEnv.runGolden else {
            throw XCTSkip("Golden run enabled via GLMOCR_RUN_GOLDEN=1; skipping smoke forward-pass test.")
        }
        guard GLMOCRTestEnv.runForwardPass else {
            throw XCTSkip("Set GLMOCR_TEST_RUN_FORWARD_PASS=1 to enable this integration test.")
        }
        guard let modelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_SNAPSHOT_PATH to a local HF snapshot folder to enable this test.")
        }

        try ensureMLXMetalLibraryColocated(for: Self.self)

        let config = try GLMOCRConfig.load(from: modelFolder)
        let tokenizer = try await GLMOCRTokenizer.load(from: modelFolder, config: config)

        let prompt = " OCR:"
        let processed = try deterministicProcessedImage(modelFolder: modelFolder, config: config)

        let inputIds = try buildInputIds(tokenizer: tokenizer, numImageTokens: processed.numImageTokens, prompt: prompt)
        let inputIdArray = MLXArray(inputIds.map { Int32($0) }).reshaped(1, -1)

        let model = try await GLMOCRModel.load(from: modelFolder)
        let logits = try model.forward(inputIds: inputIdArray, pixelValues: processed.pixelValues)
        try checkedEval(logits)

        XCTAssertEqual(logits.shape, [1, inputIds.count, config.textConfig.vocabSize ?? 59392])
    }

    private struct TopPair: Sendable {
        let id: Int
        let logit: Float
    }

    func testForwardPass_goldenSlice_matchesPython() async throws {
        guard GLMOCRTestEnv.runGolden else {
            throw XCTSkip("Set GLMOCR_RUN_GOLDEN=1 to enable this integration test.")
        }
        guard let modelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_SNAPSHOT_PATH to a local HF snapshot folder to enable this test.")
        }

        let fixtureData = try GLMOCRTestEnv.goldenFixtureData()
        let fixture = try JSONDecoder().decode(GLMOCRForwardGoldenFixture.self, from: fixtureData)

        try ensureMLXMetalLibraryColocated(for: Self.self)

        let config = try GLMOCRConfig.load(from: modelFolder)
        let tokenizer = try await GLMOCRTokenizer.load(from: modelFolder, config: config)
        let ids = tokenizer.specialTokenIDs

        XCTAssertEqual(fixture.prompt, " OCR:")
        XCTAssertEqual(fixture.config.vocabSize, config.textConfig.vocabSize ?? 59392)

        XCTAssertEqual(fixture.tokenIDs.padId, config.textConfig.padTokenId)
        XCTAssertEqual(fixture.tokenIDs.eosId, ids.eosId)
        XCTAssertEqual(fixture.tokenIDs.gMaskId, ids.gMaskId)
        XCTAssertEqual(fixture.tokenIDs.sopId, ids.sopId)
        XCTAssertEqual(fixture.tokenIDs.systemId, ids.systemId)
        XCTAssertEqual(fixture.tokenIDs.userId, ids.userId)
        XCTAssertEqual(fixture.tokenIDs.assistantId, ids.assistantId)
        XCTAssertEqual(fixture.tokenIDs.beginImageId, ids.beginImageId)
        XCTAssertEqual(fixture.tokenIDs.imageId, ids.imageId)
        XCTAssertEqual(fixture.tokenIDs.endImageId, ids.endImageId)

        let imageSize = config.visionConfig.imageSize ?? 336
        let temporalPatchSize = config.visionConfig.temporalPatchSize ?? 2
        XCTAssertEqual(fixture.config.imageSize, imageSize)
        XCTAssertEqual(fixture.config.temporalPatchSize, temporalPatchSize)
        XCTAssertEqual(fixture.config.patchSize, config.visionConfig.patchSize ?? 14)
        XCTAssertEqual(fixture.config.mergeSize, config.visionConfig.spatialMergeSize ?? 2)

        let processed = try deterministicProcessedImage(modelFolder: modelFolder, config: config)
        XCTAssertEqual(fixture.derived.numImageTokens, processed.numImageTokens)

        let inputIds = try buildInputIds(
            tokenizer: tokenizer,
            numImageTokens: processed.numImageTokens,
            prompt: fixture.prompt
        )
        XCTAssertEqual(fixture.derived.seqLen, inputIds.count)

        let model = try await GLMOCRModel.load(from: modelFolder)

        #if DEBUG
            if ProcessInfo.processInfo.environment["GLMOCR_DEBUG_VISION"] == "1" {
                let vision = model._debugCore.model.visual(processed.pixelValues)
                try checkedEval(vision)

                let visionF = vision.asType(.float32)
                let flat = visionF.asArray(Float.self)

                var sum = 0.0
                for v in flat {
                    sum += Double(v)
                }
                let mean = sum / Double(max(flat.count, 1))

                var varSum = 0.0
                for v in flat {
                    let d = Double(v) - mean
                    varSum += d * d
                }
                let denom = Double(max(flat.count - 1, 1))
                let std = (varSum / denom).squareRoot()

                let row0 = visionF[0, 0].asArray(Float.self)
                let rowLast = visionF[0, -1].asArray(Float.self)
                func l2(_ row: [Float]) -> Double {
                    var acc = 0.0
                    for v in row {
                        acc += Double(v) * Double(v)
                    }
                    return acc.squareRoot()
                }

                FileHandle.standardError.write(Data("VISION_STATS mean=\(mean) std_unbiased=\(std)\n".utf8))
                FileHandle.standardError.write(Data("VISION_ROW0 first5=\(Array(row0.prefix(5))) l2=\(l2(row0))\n".utf8))
                FileHandle.standardError.write(
                    Data("VISION_ROWLAST first5=\(Array(rowLast.prefix(5))) l2=\(l2(rowLast))\n".utf8)
                )
            }
        #endif

        let inputIdArray = MLXArray(inputIds.map { Int32($0) }).reshaped(1, -1)
        let logits = try model.forward(inputIds: inputIdArray, pixelValues: processed.pixelValues)
        try checkedEval(logits)

        XCTAssertEqual(logits.shape, [1, inputIds.count, fixture.config.vocabSize])

        let last = logits[0, -1].asType(.float32).asArray(Float.self)
        let top = topK(last, k: fixture.topKLast.count)
        XCTAssertEqual(top.map(\.id), fixture.topKLast)

        try assertLogitsSliceMatches(
            logits: logits,
            fixture: fixture,
            tolerance: 0.50
        )
    }

    private struct PreprocessorConfig: Decodable, Sendable {
        var imageMean: [Float]?
        var imageStd: [Float]?

        private enum CodingKeys: String, CodingKey {
            case imageMean = "image_mean"
            case imageStd = "image_std"
        }
    }

    private enum DeterministicImageError: Error, Sendable {
        case cgImageCreationFailed
    }

    private func deterministicProcessedImage(modelFolder: URL, config: GLMOCRConfig) throws -> GLMOCRProcessedImage {
        let imageSize = config.visionConfig.imageSize ?? 336
        let image = try makeDeterministicCIImage(imageSize: imageSize)

        var options = GLMOCRImageProcessingOptions()
        if GLMOCRTestEnv.runGolden {
            options.dtype = .float16
        }
        if let meanStd = try loadMeanStd(from: modelFolder) {
            options.mean = meanStd.mean
            options.std = meanStd.std
        }

        let processor = GLMOCRImageProcessor(options: options)
        return try processor.process(image, config: config)
    }

    private func loadMeanStd(from modelFolder: URL) throws -> (mean: (Float, Float, Float), std: (Float, Float, Float))? {
        let url = modelFolder.appendingPathComponent("preprocessor_config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(PreprocessorConfig.self, from: data)
        guard let mean = config.imageMean, let std = config.imageStd, mean.count == 3, std.count == 3 else {
            return nil
        }
        return ((mean[0], mean[1], mean[2]), (std[0], std[1], std[2]))
    }

    private func makeDeterministicCIImage(imageSize: Int) throws -> CIImage {
        let width = max(imageSize, 1)
        let height = max(imageSize, 1)
        let wDenom = max(width - 1, 1)
        let hDenom = max(height - 1, 1)
        let bDenom = max((width - 1) + (height - 1), 1)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            let g = (y * 255) / hDenom
            for x in 0 ..< width {
                let r = (x * 255) / wDenom
                let b = ((x + y) * 255) / bDenom
                let idx = (y * width + x) * 4
                pixels[idx + 0] = UInt8(r)
                pixels[idx + 1] = UInt8(g)
                pixels[idx + 2] = UInt8(b)
                pixels[idx + 3] = 255
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw DeterministicImageError.cgImageCreationFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        guard let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw DeterministicImageError.cgImageCreationFailed
        }

        return CIImage(cgImage: cg)
    }

    private func buildInputIds(tokenizer: GLMOCRTokenizer, numImageTokens: Int, prompt: String) throws -> [Int] {
        let ids = tokenizer.specialTokenIDs
        let promptTokenIDs = tokenizer.tokenizer.encode(text: prompt, addSpecialTokens: false)

        var inputIds: [Int] = [ids.gMaskId, ids.sopId, ids.userId, ids.beginImageId]
        inputIds.append(contentsOf: Array(repeating: ids.imageId, count: numImageTokens))
        inputIds.append(ids.endImageId)
        inputIds.append(contentsOf: promptTokenIDs)
        return inputIds
    }

    private func assertLogitsSliceMatches(
        logits: MLXArray,
        fixture: GLMOCRForwardGoldenFixture,
        tolerance: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(fixture.logitsSlice.count, fixture.positions.count, file: file, line: line)
        for row in fixture.logitsSlice {
            XCTAssertEqual(row.count, fixture.vocabIndices.count, file: file, line: line)
        }

        for (posIndex, position) in fixture.positions.enumerated() {
            let vec = logits[0, position].asType(.float32).asArray(Float.self)
            for (colIndex, vocabIndex) in fixture.vocabIndices.enumerated() {
                let expected = fixture.logitsSlice[posIndex][colIndex]
                let actual = vec[vocabIndex]
                XCTAssertEqual(actual, expected, accuracy: tolerance, file: file, line: line)
            }
        }
    }

    private func topK(_ values: [Float], k: Int) -> [TopPair] {
        precondition(k > 0)
        return values.indices
            .sorted { values[$0] > values[$1] }
            .prefix(k)
            .map { TopPair(id: $0, logit: values[$0]) }
    }
}
