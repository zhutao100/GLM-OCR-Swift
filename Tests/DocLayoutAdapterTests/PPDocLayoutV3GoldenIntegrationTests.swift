import CoreGraphics
import CoreImage
@testable import DocLayoutAdapter
import Foundation
import MLX
import XCTest

final class PPDocLayoutV3GoldenIntegrationTests: XCTestCase {
    func testForwardRawOutputs_goldenSlice_matchesPython() async throws {
        guard DocLayoutTestEnv.runGolden else {
            throw XCTSkip("Set LAYOUT_RUN_GOLDEN=1 to enable this integration test.")
        }
        guard let modelFolder = DocLayoutTestEnv.snapshotFolderURL else {
            throw XCTSkip("Set LAYOUT_SNAPSHOT_PATH to a local PP-DocLayout-V3 HF snapshot folder to enable this test.")
        }

        let fixtureData = try DocLayoutTestEnv.goldenFixtureData()
        let fixture = try JSONDecoder().decode(PPDocLayoutV3ForwardGoldenFixture.self, from: fixtureData)

        guard fixture.metadata.dtype == "float16" else {
            throw XCTSkip("Golden fixture dtype must be float16 (expected when generated on mps). Regenerate with --device mps.")
        }

        try ensureMLXMetalLibraryColocated(for: Self.self)

        let preprocessorConfig = try PPDocLayoutV3PreprocessorConfig.load(from: modelFolder)

        let image = try makeDeterministicCIImage(imageSize: fixture.processor.imageSize)
        let processor = PPDocLayoutV3Processor(
            dtype: .float16,
            fallbackMeanStd: ((0, 0, 0), (1, 1, 1))
        )
        let processed = try processor.process(image, preprocessorConfig: preprocessorConfig)

        let model = try PPDocLayoutV3Model.load(from: modelFolder)
        let raw = try model.forwardRawOutputs(pixelValues: processed.pixelValues)

        XCTAssertEqual(raw.logits.shape, fixture.model.logitsShape)
        XCTAssertEqual(raw.predBoxes.shape, fixture.model.predBoxesShape)

        XCTAssertEqual(fixture.queryIndices.count, fixture.logitsSlice.count)
        XCTAssertEqual(fixture.queryIndices.count, fixture.predBoxesSlice.count)
        for row in fixture.logitsSlice {
            XCTAssertEqual(row.count, fixture.classIndices.count)
        }

        let logitsTolerance: Float = 0.50
        let boxesTolerance: Float = 0.02

        for (rowIndex, queryIndex) in fixture.queryIndices.enumerated() {
            let logits = raw.logits[0, queryIndex].asType(.float32).asArray(Float.self)
            for (colIndex, classIndex) in fixture.classIndices.enumerated() {
                let expected = fixture.logitsSlice[rowIndex][colIndex]
                let actual = logits[classIndex]
                XCTAssertEqual(actual, expected, accuracy: logitsTolerance)
            }

            let box = raw.predBoxes[0, queryIndex].asType(.float32).asArray(Float.self)
            XCTAssertEqual(box.count, 4)
            for i in 0 ..< 4 {
                let expected = fixture.predBoxesSlice[rowIndex][i]
                let actual = box[i]
                XCTAssertEqual(actual, expected, accuracy: boxesTolerance)
            }
        }
    }

    private enum DeterministicImageError: Error, Sendable {
        case cgImageCreationFailed
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
}
