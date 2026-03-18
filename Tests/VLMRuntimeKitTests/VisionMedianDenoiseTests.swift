import CoreGraphics
import CoreImage
import VLMRuntimeKit
import XCTest

final class VisionMedianDenoiseTests: XCTestCase {
    func testApplyMedianDenoise_removesIsolatedDarkPixel() throws {
        let w = 7
        let h = 7

        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let center = ((h / 2) * w + (w / 2)) * 4
        bytes[center] = 0
        bytes[center + 1] = 0
        bytes[center + 2] = 0
        bytes[center + 3] = 255

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let image = CIImage(
            bitmapData: Data(bytes),
            bytesPerRow: w * 4,
            size: CGSize(width: w, height: h),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        let denoised = try VisionIO.applyMedianDenoise(image)
        let rgba = try VisionRaster.renderRGBA8(denoised)

        let outBytes = [UInt8](rgba.data)
        XCTAssertEqual(outBytes[center + 3], 255)
        XCTAssertGreaterThan(outBytes[center], 200)
        XCTAssertGreaterThan(outBytes[center + 1], 200)
        XCTAssertGreaterThan(outBytes[center + 2], 200)
    }
}
