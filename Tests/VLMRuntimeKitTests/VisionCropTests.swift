import CoreGraphics
import CoreImage
import VLMRuntimeKit
import XCTest

final class VisionCropTests: XCTestCase {
    func testCropRegion_bboxComputesCorrectExtentWithYFlip() throws {
        let image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))

        let bbox = OCRNormalizedBBox(x1: 100, y1: 200, x2: 400, y2: 700)
        let cropped = try VisionIO.cropRegion(image: image, bbox: bbox, polygon: nil)

        XCTAssertEqual(cropped.extent, CGRect(x: 100, y: 300, width: 300, height: 500))
    }

    func testCropRegion_polygonMasksOutsideToFillColor() throws {
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))

        let bbox = OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000)
        let polygon: [OCRNormalizedPoint] = [
            .init(x: 0, y: 0),
            .init(x: 500, y: 0),
            .init(x: 500, y: 1000),
            .init(x: 0, y: 1000),
        ]

        let output = try VisionIO.cropRegion(image: image, bbox: bbox, polygon: polygon, fillColor: .white)

        let inside = try renderRGBA8Pixel(in: output, x: 250, y: 500)
        XCTAssertGreaterThan(inside.r, 200)
        XCTAssertLessThan(inside.g, 50)
        XCTAssertLessThan(inside.b, 50)

        let outside = try renderRGBA8Pixel(in: output, x: 750, y: 500)
        XCTAssertGreaterThan(outside.r, 200)
        XCTAssertGreaterThan(outside.g, 200)
        XCTAssertGreaterThan(outside.b, 200)
    }

    // swiftlint:disable:next large_tuple
    private func renderRGBA8Pixel(in image: CIImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
    {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let bounds = CGRect(x: x, y: y, width: 1, height: 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else {
                throw XCTSkip("Unable to allocate pixel buffer.")
            }
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            context.render(
                image,
                toBitmap: baseAddress,
                rowBytes: 4,
                bounds: bounds,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
