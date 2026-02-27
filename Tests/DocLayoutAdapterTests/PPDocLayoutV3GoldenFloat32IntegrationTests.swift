import CoreImage
import Foundation
import MLX
import XCTest

@testable import DocLayoutAdapter

final class PPDocLayoutV3GoldenFloat32IntegrationTests: XCTestCase {
    func testForwardRawOutputs_cpuFloat32_goldenSlice_matchesPython() async throws {
        guard DocLayoutTestEnv.runGolden else {
            throw XCTSkip("Set LAYOUT_RUN_GOLDEN=1 to enable this integration test.")
        }
        guard let modelFolder = DocLayoutTestEnv.snapshotFolderURL else {
            throw XCTSkip("Set LAYOUT_SNAPSHOT_PATH to a local PP-DocLayout-V3 HF snapshot folder to enable this test.")
        }

        let fixtureData = try DocLayoutTestEnv.goldenFixtureData(name: "ppdoclayoutv3_forward_golden_cpu_float32_v1")
        let fixture = try JSONDecoder().decode(PPDocLayoutV3ForwardGoldenFixture.self, from: fixtureData)

        guard fixture.metadata.dtype == "float32" else {
            throw XCTSkip("Golden fixture dtype must be float32. Regenerate with --device cpu.")
        }

        try ensureMLXMetalLibraryColocated(for: Self.self)

        let preprocessorConfig = try PPDocLayoutV3PreprocessorConfig.load(from: modelFolder)

        let image = try makeDeterministicCIImage(imageSize: fixture.processor.imageSize)
        let processor = PPDocLayoutV3Processor(
            dtype: .float32,
            fallbackMeanStd: ((0, 0, 0), (1, 1, 1))
        )
        let processed = try processor.process(image, preprocessorConfig: preprocessorConfig)

        let model = try PPDocLayoutV3Model.load(from: modelFolder, weightsDTypeOverride: .float32)
        let raw = try model.forwardRawOutputs(
            pixelValues: processed.pixelValues,
            encoderTopKIndicesOverride: fixture.encoderTopKIndices
        )

        XCTAssertEqual(raw.logits.shape, fixture.model.logitsShape)
        XCTAssertEqual(raw.predBoxes.shape, fixture.model.predBoxesShape)

        let logitsTolerance: Float = 0.10
        let boxesTolerance: Float = 0.01

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

            let logits = raw.logits[0, swiftQueryIndex].asArray(Float.self)
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

            let box = raw.predBoxes[0, swiftQueryIndex].asArray(Float.self)
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
