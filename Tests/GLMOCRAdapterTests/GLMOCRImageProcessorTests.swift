import CoreImage
import MLX
import XCTest

@testable import GLMOCRAdapter

final class GLMOCRImageProcessorTests: XCTestCase {
    func testProcess_handlesNonZeroOriginExtent() throws {
        try ensureMLXMetalLibraryColocated(for: Self.self)

        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
            .cropped(to: CGRect(x: 2000, y: 3000, width: 120, height: 80))

        let config = GLMOCRConfig(
            textConfig: .init(),
            visionConfig: .init(patchSize: 14, temporalPatchSize: 2, spatialMergeSize: 2)
        )

        let processor = GLMOCRImageProcessor(options: .init(dtype: .float32))
        let processed = try processor.process(image, config: config)

        XCTAssertEqual(processed.pixelValues.shape.count, 5)
        XCTAssertEqual(processed.pixelValues.shape.first, 1)
        XCTAssertEqual(processed.pixelValues.shape.last, 3)
        XCTAssertGreaterThan(processed.pixelValues.shape[2], 0)
        XCTAssertGreaterThan(processed.pixelValues.shape[3], 0)
    }

    func testProcess_deterministicBackend_matchesTokenCountAndShape() throws {
        try ensureMLXMetalLibraryColocated(for: Self.self)

        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
            .cropped(to: CGRect(x: 100, y: 200, width: 120, height: 80))

        let config = GLMOCRConfig(
            textConfig: .init(),
            visionConfig: .init(patchSize: 14, temporalPatchSize: 2, spatialMergeSize: 2)
        )

        let baseOptions = GLMOCRImageProcessingOptions(dtype: .float32)
        let coreImage = GLMOCRImageProcessor(options: baseOptions)
        let coreProcessed = try coreImage.process(image, config: config)

        var deterministicOptions = baseOptions
        deterministicOptions.resizeBackend = .deterministicBicubicCPU
        let deterministic = GLMOCRImageProcessor(options: deterministicOptions)
        let deterministicProcessed = try deterministic.process(image, config: config)

        XCTAssertEqual(deterministicProcessed.numImageTokens, coreProcessed.numImageTokens)
        XCTAssertEqual(deterministicProcessed.pixelValues.shape, coreProcessed.pixelValues.shape)
    }
}
