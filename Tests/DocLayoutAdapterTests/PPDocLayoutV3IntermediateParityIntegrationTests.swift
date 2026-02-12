import CoreImage
@testable import DocLayoutAdapter
import Foundation
import MLX
import XCTest

final class PPDocLayoutV3IntermediateParityIntegrationTests: XCTestCase {
    func testForwardRawOutputs_cpuFloat32_intermediates_matchPython() async throws {
        guard DocLayoutTestEnv.runGolden else {
            throw XCTSkip("Set LAYOUT_RUN_GOLDEN=1 to enable this integration test.")
        }
        guard let modelFolder = DocLayoutTestEnv.snapshotFolderURL else {
            throw XCTSkip("Set LAYOUT_SNAPSHOT_PATH to a local PP-DocLayout-V3 HF snapshot folder to enable this test.")
        }

        let fixtureData = try DocLayoutTestEnv.goldenFixtureData(name: "ppdoclayoutv3_forward_golden_cpu_float32_v3")
        let fixture = try JSONDecoder().decode(PPDocLayoutV3ForwardGoldenFixture.self, from: fixtureData)

        guard fixture.metadata.dtype == "float32" else {
            throw XCTSkip("Fixture dtype must be float32. Regenerate with --device cpu.")
        }
        guard let intermediates = fixture.intermediates else {
            throw XCTSkip("Fixture missing intermediates. Regenerate with --include-intermediates.")
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

        var requested: [String: [[Int]]] = [:]
        requested.reserveCapacity(intermediates.tensors.count)
        for (name, tensor) in intermediates.tensors {
            requested[name] = tensor.samples.map(\.index)
        }
        let probe = PPDocLayoutV3IntermediateProbe(requested: requested)

        _ = try model.forwardRawOutputs(
            pixelValues: processed.pixelValues,
            encoderTopKIndicesOverride: fixture.encoderTopKIndices,
            probe: probe
        )

        let atol: Float = 1e-3

        for name in intermediates.order {
            guard let expected = intermediates.tensors[name] else {
                XCTFail("Fixture intermediates missing tensor: \(name)")
                continue
            }
            guard let actual = probe.captures[name] else {
                XCTFail("Swift probe did not capture tensor: \(name)")
                continue
            }

            XCTAssertEqual(actual.shape, expected.shape, "tensor=\(name) shape mismatch")

            func key(_ index: [Int]) -> String {
                index.map(String.init).joined(separator: ",")
            }

            let expectedByIndex = Dictionary(uniqueKeysWithValues: expected.samples.map { (key($0.index), $0.value) })
            let actualByIndex = Dictionary(uniqueKeysWithValues: actual.samples.map { (key($0.index), $0.value) })

            for (k, expectedValue) in expectedByIndex {
                guard let actualValue = actualByIndex[k] else {
                    XCTFail("Missing Swift sample tensor=\(name) index=\(k)")
                    continue
                }
                XCTAssertEqual(actualValue, expectedValue, accuracy: atol, "tensor=\(name) index=\(k)")
            }
        }
    }
}
