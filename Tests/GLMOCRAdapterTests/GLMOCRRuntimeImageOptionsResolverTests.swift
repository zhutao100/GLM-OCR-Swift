import MLX
import XCTest

@testable import GLMOCRAdapter

final class GLMOCRRuntimeImageOptionsResolverTests: XCTestCase {
    func testResolve_defaultsToVisionWeightDTypeAlignment() {
        let options = GLMOCRRuntimeImageOptionsResolver.resolve(
            env: [:],
            normalizationStats: nil,
            visionInputDType: .float16
        )

        XCTAssertTrue(options.alignDTypeToVisionWeights)
        XCTAssertEqual(options.dtype, .float16)
        XCTAssertEqual(options.resizeBackend, .coreImageBicubic)
    }

    func testResolve_canDisableDefaultVisionWeightAlignment() {
        let options = GLMOCRRuntimeImageOptionsResolver.resolve(
            env: ["GLMOCR_ALIGN_VISION_DTYPE": "0"],
            normalizationStats: nil,
            visionInputDType: .float16
        )

        XCTAssertFalse(options.alignDTypeToVisionWeights)
        XCTAssertEqual(options.dtype, .bfloat16)
    }

    func testResolve_explicitDTypeOverrideWinsOverAlignment() {
        let options = GLMOCRRuntimeImageOptionsResolver.resolve(
            env: [
                "GLMOCR_ALIGN_VISION_DTYPE": "1",
                "GLMOCR_VISION_INPUT_DTYPE": "float32",
            ],
            normalizationStats: nil,
            visionInputDType: .float16
        )

        XCTAssertFalse(options.alignDTypeToVisionWeights)
        XCTAssertEqual(options.dtype, .float32)
    }

    func testResolve_appliesBackendJpegQualityAndNormalizationStats() {
        let options = GLMOCRRuntimeImageOptionsResolver.resolve(
            env: [
                "GLMOCR_PREPROCESS_BACKEND": "deterministic",
                "GLMOCR_POST_RESIZE_JPEG_QUALITY": "0.85",
            ],
            normalizationStats: GLMOCRNormalizationStats(
                mean: (0.1, 0.2, 0.3),
                std: (0.4, 0.5, 0.6)
            ),
            visionInputDType: .float16
        )

        XCTAssertEqual(options.resizeBackend, .deterministicBicubicCPU)
        XCTAssertNotNil(options.postResizeJPEGRoundTripQuality)
        XCTAssertEqual(options.postResizeJPEGRoundTripQuality ?? 0, 0.85, accuracy: 0.000_1)
        XCTAssertEqual(options.mean.0, 0.1, accuracy: 0.000_1)
        XCTAssertEqual(options.mean.1, 0.2, accuracy: 0.000_1)
        XCTAssertEqual(options.mean.2, 0.3, accuracy: 0.000_1)
        XCTAssertEqual(options.std.0, 0.4, accuracy: 0.000_1)
        XCTAssertEqual(options.std.1, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(options.std.2, 0.6, accuracy: 0.000_1)
    }

    func testResolve_usesPreferredBackendWhenEnvDoesNotOverrideIt() {
        let options = GLMOCRRuntimeImageOptionsResolver.resolve(
            env: [:],
            normalizationStats: nil,
            visionInputDType: .bfloat16,
            preferredResizeBackend: .deterministicBicubicCPU
        )

        XCTAssertEqual(options.resizeBackend, .deterministicBicubicCPU)
    }

    func testResolve_explicitBackendEnvOverridesPreferredBackend() {
        let options = GLMOCRRuntimeImageOptionsResolver.resolve(
            env: ["GLMOCR_PREPROCESS_BACKEND": "coreimage"],
            normalizationStats: nil,
            visionInputDType: .bfloat16,
            preferredResizeBackend: .deterministicBicubicCPU
        )

        XCTAssertEqual(options.resizeBackend, .coreImageBicubic)
    }
}
