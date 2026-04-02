import CoreGraphics
import CoreImage
import Foundation
import VLMRuntimeKit
import XCTest

final class VisionIOTests: MLXTestCase {
    func testLoadCIImage_fromPDF_rendersNonEmptyImage() throws {
        let pdfData = try makeOnePagePDF()
        let tempDir = try makeWorkspaceTempDir(prefix: "vlmruntimekit_visionio_test")
        defer { _ = try? FileManager.default.removeItem(at: tempDir) }
        let url =
            tempDir
            .appendingPathComponent("input")
            .appendingPathExtension("pdf")
        try pdfData.write(to: url)

        let image = try VisionIO.loadCIImage(fromPDF: url, page: 1, dpi: 72)
        XCTAssertGreaterThan(image.extent.width, 0)
        XCTAssertGreaterThan(image.extent.height, 0)
    }

    func testPDFPageCount_returnsCorrectCount() throws {
        let pdfData = try makeTwoPagePDF()
        let tempDir = try makeWorkspaceTempDir(prefix: "vlmruntimekit_visionio_pagecount_test")
        defer { _ = try? FileManager.default.removeItem(at: tempDir) }
        let url =
            tempDir
            .appendingPathComponent("input")
            .appendingPathExtension("pdf")
        try pdfData.write(to: url)

        let count = try VisionIO.pdfPageCount(url: url)
        XCTAssertEqual(count, 2)
    }

    func testImageTensorConverter_convertsAndNormalizes() throws {
        let ci = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))

        let options = ImageTensorConversionOptions(
            dtype: .float32,
            mean: (0.5, 0.5, 0.5),
            std: (0.5, 0.5, 0.5)
        )
        let tensor = try ImageTensorConverter.toTensor(ci, options: options)

        XCTAssertEqual(tensor.tensor.shape, [1, 2, 2, 3])

        let values = tensor.tensor.asType(.float32).asArray(Float.self)
        XCTAssertEqual(values.count, 12)

        // First pixel (red) after (x - 0.5) / 0.5 normalization.
        XCTAssertEqual(values[0], 1.0, accuracy: 0.1)
        XCTAssertEqual(values[1], -1.0, accuracy: 0.1)
        XCTAssertEqual(values[2], -1.0, accuracy: 0.1)
    }

    func testVisionRaster_renderRGBA8_producesExpectedByteCount() throws {
        let ci = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
            .cropped(to: CGRect(x: 2000, y: 3000, width: 3, height: 2))

        let rgba = try VisionRaster.renderRGBA8(ci)
        XCTAssertEqual(rgba.width, 3)
        XCTAssertEqual(rgba.height, 2)
        XCTAssertEqual(rgba.data.count, 3 * 2 * 4)
    }

    func testVisionResize_bicubicRGB_producesExpectedOutputSize() throws {
        let rgbaBytes: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]
        let rgba = RGBA8Image(data: Data(rgbaBytes), width: 2, height: 2)
        let resized = try VisionResize.bicubicRGB(from: rgba, toWidth: 3, toHeight: 4)

        XCTAssertEqual(resized.width, 3)
        XCTAssertEqual(resized.height, 4)
        XCTAssertEqual(resized.data.count, 3 * 4 * 3)
    }

    func testVisionJPEG_roundTrip_preservesDimensions() throws {
        let rgbBytes: [UInt8] = [
            255, 0, 0, 0, 255, 0,
            0, 0, 255, 255, 255, 255,
        ]
        let rgb = RGB8Image(data: Data(rgbBytes), width: 2, height: 2)
        let roundTripped = try VisionJPEG.roundTrip(rgb, quality: 0.95)

        XCTAssertEqual(roundTripped.width, 2)
        XCTAssertEqual(roundTripped.height, 2)
        XCTAssertEqual(roundTripped.data.count, 2 * 2 * 3)
    }

    func testImageTensorConverter_convertsFromRGB8Image() throws {
        var data = Data(capacity: 2 * 2 * 3)
        for _ in 0..<4 {
            data.append(255)  // r
            data.append(0)  // g
            data.append(0)  // b
        }

        let rgb = RGB8Image(data: data, width: 2, height: 2)
        let options = ImageTensorConversionOptions(
            dtype: .float32,
            mean: (0.5, 0.5, 0.5),
            std: (0.5, 0.5, 0.5)
        )
        let tensor = try ImageTensorConverter.toTensor(rgb, options: options)

        XCTAssertEqual(tensor.tensor.shape, [1, 2, 2, 3])
        let values = tensor.tensor.asType(.float32).asArray(Float.self)
        XCTAssertEqual(values.count, 12)

        // First pixel (red) after (x - 0.5) / 0.5 normalization.
        XCTAssertEqual(values[0], 1.0, accuracy: 0.1)
        XCTAssertEqual(values[1], -1.0, accuracy: 0.1)
        XCTAssertEqual(values[2], -1.0, accuracy: 0.1)
    }

    private func makeOnePagePDF() throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw XCTSkip("CGDataConsumer init failed")
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("PDF CGContext init failed")
        }

        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(mediaBox)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 120, height: 60))
        ctx.endPDFPage()
        ctx.closePDF()

        return data as Data
    }

    private func makeTwoPagePDF() throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw XCTSkip("CGDataConsumer init failed")
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("PDF CGContext init failed")
        }

        for idx in 0..<2 {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(mediaBox)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20 + CGFloat(idx) * 10, y: 20, width: 120, height: 60))
            ctx.endPDFPage()
        }

        ctx.closePDF()
        return data as Data
    }
}
