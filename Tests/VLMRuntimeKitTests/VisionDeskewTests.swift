import CoreGraphics
import CoreImage
import VLMRuntimeKit
import XCTest

final class VisionDeskewTests: XCTestCase {
    func testEstimateDeskewAngle_returnsNilOnUprightHorizontalLines() throws {
        let image = makeHorizontalLineImage(width: 360, height: 240, lineCount: 10)
        let estimate = try VisionIO.estimateDeskewAngle(for: image)
        XCTAssertNil(estimate)
    }

    func testEstimateDeskewAngle_detectsSmallAngleSkew_andCorrectionNeutralizes() throws {
        let base = makeHorizontalLineImage(width: 420, height: 300, lineCount: 12)
        let skewed = try VisionIO.applyDeskew(base, angleDegrees: 2.0, fillColor: .white)

        var options = VisionDeskewOptions()
        options.minApplyAngleDegrees = 0
        options.minConfidence = 0
        let estimate = try XCTUnwrap(VisionIO.estimateDeskewAngle(for: skewed, options: options))

        XCTAssertLessThan(estimate.angleDegrees, -0.5)
        XCTAssertGreaterThan(abs(estimate.angleDegrees), 1.0)

        let corrected = try VisionIO.applyDeskew(skewed, angleDegrees: estimate.angleDegrees, fillColor: .white)
        let correctedEstimate = try VisionIO.estimateDeskewAngle(for: corrected)
        XCTAssertNil(correctedEstimate)
    }

    private func makeHorizontalLineImage(width: Int, height: Int, lineCount: Int) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(color: CIColor.white).cropped(to: extent)

        let lineHeight: CGFloat = 2
        let marginX: CGFloat = 22
        let marginY: CGFloat = 18
        let spacing = CGFloat(height - Int(2 * marginY)) / CGFloat(max(lineCount, 1))

        for i in 0..<max(lineCount, 1) {
            let y = marginY + CGFloat(i) * spacing
            let lineRect = CGRect(
                x: 0,
                y: 0,
                width: max(CGFloat(width) - 2 * marginX, 1),
                height: lineHeight
            )
            let line = CIImage(color: CIColor.black)
                .cropped(to: lineRect)
                .transformed(by: CGAffineTransform(translationX: marginX, y: y))
            image = line.composited(over: image)
        }

        return image
    }
}
