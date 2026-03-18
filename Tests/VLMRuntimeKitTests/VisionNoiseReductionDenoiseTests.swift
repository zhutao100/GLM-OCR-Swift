import CoreImage
import VLMRuntimeKit
import XCTest

final class VisionNoiseReductionDenoiseTests: XCTestCase {
    func testApplyNoiseReductionDenoise_keepsUniformImageStable() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 48)
        let image = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)).cropped(to: extent)

        let denoised = try VisionIO.applyNoiseReductionDenoise(image)
        XCTAssertEqual(denoised.extent.integral, extent)

        let before = try VisionRaster.renderRGBA8(image)
        let after = try VisionRaster.renderRGBA8(denoised)
        XCTAssertEqual(before, after)
    }
}
