import CoreGraphics
import CoreImage
import VLMRuntimeKit
import XCTest

final class VisionBorderCleanupTests: XCTestCase {
    func testProposeBorderCleanupCrop_detectsDarkBorderAndCropsWithSafetyBorder() throws {
        let imageWidth = 100
        let imageHeight = 80
        let border = 10
        let image = makeBorderedImage(
            width: imageWidth,
            height: imageHeight,
            border: border,
            borderColor: CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            innerColor: CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        )

        let options = VisionBorderCleanupOptions(
            maxAnalysisDimension: 512,
            minBorderPixels: 5,
            safetyBorderPixels: 4
        )

        let proposal = try XCTUnwrap(VisionIO.proposeBorderCleanupCrop(for: image, options: options))
        XCTAssertGreaterThan(proposal.confidence, 0.50)

        XCTAssertEqual(proposal.bbox.x1, 60)
        XCTAssertEqual(proposal.bbox.x2, 940)
        XCTAssertEqual(proposal.bbox.y1, 75)
        XCTAssertEqual(proposal.bbox.y2, 925)

        let cropped = try VisionIO.applyBorderCleanupCrop(image, proposal: proposal)
        XCTAssertEqual(cropped.extent, CGRect(x: 6, y: 6, width: 88, height: 68))
    }

    func testProposeBorderCleanupCrop_returnsNilOnUniformPage() throws {
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 120, height: 90))

        let proposal = try VisionIO.proposeBorderCleanupCrop(for: image)
        XCTAssertNil(proposal)
    }

    func testProposeBorderCleanupCrop_returnsNilWhenBorderBelowMinimumThickness() throws {
        let image = makeBorderedImage(
            width: 120,
            height: 90,
            border: 4,
            borderColor: CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            innerColor: CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        )

        let options = VisionBorderCleanupOptions(minBorderPixels: 12)
        let proposal = try VisionIO.proposeBorderCleanupCrop(for: image, options: options)
        XCTAssertNil(proposal)
    }

    private func makeBorderedImage(
        width: Int,
        height: Int,
        border: Int,
        borderColor: CIColor,
        innerColor: CIColor
    ) -> CIImage {
        let baseRect = CGRect(x: 0, y: 0, width: width, height: height)
        let base = CIImage(color: borderColor).cropped(to: baseRect)

        let innerRect = CGRect(x: 0, y: 0, width: width - 2 * border, height: height - 2 * border)
        let inner = CIImage(color: innerColor)
            .cropped(to: innerRect)
            .transformed(by: CGAffineTransform(translationX: CGFloat(border), y: CGFloat(border)))

        return inner.composited(over: base)
    }
}
