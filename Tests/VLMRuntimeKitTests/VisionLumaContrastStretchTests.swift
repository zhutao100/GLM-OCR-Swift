import CoreImage
import VLMRuntimeKit
import XCTest

final class VisionLumaContrastStretchTests: XCTestCase {
    func testProposeLumaContrastStretch_returnsNilOnHighContrastImage() throws {
        let image = makeHorizontalLineImage(
            width: 200,
            height: 160,
            lineCount: 14,
            background: CIColor.white,
            lineColor: CIColor.black
        )
        let proposal = try VisionIO.proposeLumaContrastStretch(for: image)
        XCTAssertNil(proposal)
    }

    func testProposeLumaContrastStretch_detectsLowContrast_andApplyIncreasesRange() throws {
        let background = CIColor(red: 210 / 255.0, green: 210 / 255.0, blue: 210 / 255.0, alpha: 1)
        let lineColor = CIColor(red: 180 / 255.0, green: 180 / 255.0, blue: 180 / 255.0, alpha: 1)
        let image = makeHorizontalLineImage(
            width: 220,
            height: 160,
            lineCount: 12,
            background: background,
            lineColor: lineColor
        )

        var options = VisionLumaContrastStretchOptions()
        options.strength = 1.0
        options.minLumaRange = 1
        options.minScale = 1
        options.maxScale = 12

        let proposal = try XCTUnwrap(VisionIO.proposeLumaContrastStretch(for: image, options: options))
        XCTAssertGreaterThan(proposal.scale, 1.2)

        let before = try VisionRaster.renderRGBA8(image)
        let beforeRange = lumaRange(before)

        let stretched = try VisionIO.applyLumaContrastStretch(image, proposal: proposal)
        XCTAssertEqual(stretched.extent.integral, image.extent.integral)

        let after = try VisionRaster.renderRGBA8(stretched)
        let afterRange = lumaRange(after)

        XCTAssertGreaterThan(afterRange, beforeRange)
    }

    private func makeHorizontalLineImage(
        width: Int,
        height: Int,
        lineCount: Int,
        background: CIColor,
        lineColor: CIColor
    ) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(color: background).cropped(to: extent)

        let lineHeight: CGFloat = 3
        let marginX: CGFloat = 18
        let marginY: CGFloat = 14
        let spacing = CGFloat(height - Int(2 * marginY)) / CGFloat(max(lineCount, 1))

        for i in 0..<max(lineCount, 1) {
            let y = marginY + CGFloat(i) * spacing
            let lineRect = CGRect(
                x: 0,
                y: 0,
                width: max(CGFloat(width) - 2 * marginX, 1),
                height: lineHeight
            )
            let line = CIImage(color: lineColor)
                .cropped(to: lineRect)
                .transformed(by: CGAffineTransform(translationX: marginX, y: y))
            image = line.composited(over: image)
        }

        return image
    }

    private func lumaRange(_ rgba: RGBA8Image) -> Int {
        var minLuma = 255
        var maxLuma = 0

        rgba.data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = rgba.width * rgba.height
            for i in 0..<count {
                let idx = i * 4
                let r = Int(base[idx])
                let g = Int(base[idx + 1])
                let b = Int(base[idx + 2])
                let luma = (54 * r + 183 * g + 19 * b) >> 8
                minLuma = min(minLuma, luma)
                maxLuma = max(maxLuma, luma)
            }
        }

        return max(0, maxLuma - minLuma)
    }
}
