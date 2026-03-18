import CoreImage
import VLMRuntimeKit
import XCTest

final class VisionMonochromeThresholdTests: XCTestCase {
    func testProposeMonochromeThreshold_reportsLowConfidenceOnColorfulInput() throws {
        let extent = CGRect(x: 0, y: 0, width: 160, height: 100)
        let base = CIImage(color: CIColor.red).cropped(to: extent)
        let greenHalf = CIImage(color: CIColor.green)
            .cropped(to: CGRect(x: 0, y: 0, width: extent.width / 2, height: extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.width / 2, y: 0))
        let image = greenHalf.composited(over: base)

        let proposal = try XCTUnwrap(VisionIO.proposeMonochromeThreshold(for: image))
        XCTAssertLessThan(proposal.confidence, 0.05)
    }

    func testApplyMonochromeThreshold_otsuBinarizesTwoToneImage() throws {
        let extent = CGRect(x: 0, y: 0, width: 96, height: 64)
        let base = CIImage(color: CIColor.white).cropped(to: extent)
        let darkHalf = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: extent.width / 2, height: extent.height))
        let image = darkHalf.composited(over: base)

        let thresholded = try VisionIO.applyMonochromeThreshold(image)
        let rgba = try VisionRaster.renderRGBA8(thresholded)

        let (minValue, maxValue) = minMaxChannel(rgba.data)
        XCTAssertEqual(minValue, 0)
        XCTAssertEqual(maxValue, 255)
    }

    private func minMaxChannel(_ data: Data) -> (min: UInt8, max: UInt8) {
        var minValue: UInt8 = 255
        var maxValue: UInt8 = 0

        for b in data.enumerated() where b.offset % 4 == 0 {
            minValue = min(minValue, b.element)
            maxValue = max(maxValue, b.element)
        }

        return (minValue, maxValue)
    }
}
