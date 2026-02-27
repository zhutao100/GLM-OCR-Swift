import CoreImage
import Foundation
import MLX
import XCTest

@testable import DocLayoutAdapter

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
            throw XCTSkip(
                "Golden fixture dtype must be float16 (expected when generated on mps). Regenerate with --device mps.")
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
        let forcePixelFloat32 = ProcessInfo.processInfo.environment["LAYOUT_FORCE_PIXEL_FLOAT32"] == "1"
        let pixelValues = forcePixelFloat32 ? processed.pixelValues.asType(.float32) : processed.pixelValues
        let raw = try model.forwardRawOutputs(
            pixelValues: pixelValues,
            encoderTopKIndicesOverride: fixture.encoderTopKIndices
        )

        if ProcessInfo.processInfo.environment["LAYOUT_DEBUG_DTYPE"] == "1" {
            let msg =
                "PPDocLayoutV3 dtype debug: " + "processed.pixelValues=\(processed.pixelValues.dtype) "
                + "forward.pixelValues=\(pixelValues.dtype) " + "raw.logits=\(raw.logits.dtype) "
                + "raw.predBoxes=\(raw.predBoxes.dtype)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        XCTAssertEqual(raw.logits.shape, fixture.model.logitsShape)
        XCTAssertEqual(raw.predBoxes.shape, fixture.model.predBoxesShape)

        XCTAssertEqual(fixture.queryIndices.count, fixture.logitsSlice.count)
        XCTAssertEqual(fixture.queryIndices.count, fixture.predBoxesSlice.count)
        for row in fixture.logitsSlice {
            XCTAssertEqual(row.count, fixture.classIndices.count)
        }

        let logitsTolerance: Float = 0.50
        let boxesTolerance: Float = 0.02

        let swiftTopK = raw.encoderTopKIndices[0].asArray(Int32.self).map { Int($0) }
        let pythonTopK = fixture.encoderTopKIndices
        if let pythonTopK {
            XCTAssertEqual(pythonTopK.count, fixture.model.numQueries)
            XCTAssertEqual(swiftTopK.count, fixture.model.numQueries)
        }

        for (rowIndex, pythonQueryIndex) in fixture.queryIndices.enumerated() {
            let swiftQueryIndex: Int
            if let pythonTopK {
                let encoderIndex = pythonTopK[pythonQueryIndex]
                guard let mapped = swiftTopK.firstIndex(of: encoderIndex) else {
                    XCTFail(
                        "Python encoder index \(encoderIndex) not found in Swift top-k. pythonQuery=\(pythonQueryIndex)"
                    )
                    continue
                }
                swiftQueryIndex = mapped
            } else {
                swiftQueryIndex = pythonQueryIndex
            }

            let logits = raw.logits[0, swiftQueryIndex].asType(.float32).asArray(Float.self)
            for (colIndex, classIndex) in fixture.classIndices.enumerated() {
                let expected = fixture.logitsSlice[rowIndex][colIndex]
                let actual = logits[classIndex]
                XCTAssertEqual(
                    actual,
                    expected,
                    accuracy: logitsTolerance,
                    "pythonQuery=\(pythonQueryIndex) swiftQuery=\(swiftQueryIndex) class=\(classIndex)"
                )
            }

            let box = raw.predBoxes[0, swiftQueryIndex].asType(.float32).asArray(Float.self)
            XCTAssertEqual(box.count, 4)
            for i in 0..<4 {
                let expected = fixture.predBoxesSlice[rowIndex][i]
                let actual = box[i]
                XCTAssertEqual(
                    actual,
                    expected,
                    accuracy: boxesTolerance,
                    "pythonQuery=\(pythonQueryIndex) swiftQuery=\(swiftQueryIndex) box=\(i)"
                )
            }
        }
    }
}
