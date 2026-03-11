import CoreImage
import MLX
import XCTest

@testable import GLMOCRAdapter

final class GLMOCRImageProcessorTests: MLXTestCase {
    func testProcess_handlesNonZeroOriginExtent() throws {
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

    func testInspect_capturesResizedRGBAndTensorSummary() throws {
        let image = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))

        let config = GLMOCRConfig(
            textConfig: .init(),
            visionConfig: .init(patchSize: 14, temporalPatchSize: 2, spatialMergeSize: 2)
        )

        let processor = GLMOCRImageProcessor(options: .init(dtype: .float32))
        let inspection = try processor.inspect(image, config: config)

        XCTAssertEqual(inspection.originalWidth, 96)
        XCTAssertEqual(inspection.originalHeight, 64)
        XCTAssertEqual(inspection.resizedRGB.width, inspection.targetWidth)
        XCTAssertEqual(inspection.resizedRGB.height, inspection.targetHeight)
        XCTAssertEqual(inspection.tensorSummary.dtype, String(describing: DType.float32))
        XCTAssertGreaterThanOrEqual(inspection.tensorSummary.maximum, inspection.tensorSummary.minimum)
    }
}
