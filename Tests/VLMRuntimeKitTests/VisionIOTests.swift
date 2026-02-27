import CoreGraphics
import CoreImage
import Foundation
import VLMRuntimeKit
import XCTest

final class VisionIOTests: XCTestCase {
    func testLoadCIImage_fromPDF_rendersNonEmptyImage() throws {
        let pdfData = try makeOnePagePDF()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlmruntimekit_visionio_test_\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        try pdfData.write(to: url)
        defer { _ = try? FileManager.default.removeItem(at: url) }

        let image = try VisionIO.loadCIImage(fromPDF: url, page: 1, dpi: 72)
        XCTAssertGreaterThan(image.extent.width, 0)
        XCTAssertGreaterThan(image.extent.height, 0)
    }

    func testPDFPageCount_returnsCorrectCount() throws {
        let pdfData = try makeTwoPagePDF()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlmruntimekit_visionio_pagecount_test_\(UUID().uuidString)")
            .appendingPathExtension("pdf")
        try pdfData.write(to: url)
        defer { _ = try? FileManager.default.removeItem(at: url) }

        let count = try VisionIO.pdfPageCount(url: url)
        XCTAssertEqual(count, 2)
    }

    func testImageTensorConverter_convertsAndNormalizes() throws {
        try ensureMLXMetalLibraryColocated()

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

    private func ensureMLXMetalLibraryColocated() throws {
        guard let executableURL = Bundle(for: Self.self).executableURL else {
            throw XCTSkip("Cannot determine test executable location for colocating mlx.metallib.")
        }

        let binaryDir = executableURL.deletingLastPathComponent()
        let colocated = binaryDir.appendingPathComponent("mlx.metallib")
        if FileManager.default.fileExists(atPath: colocated.path) { return }

        let binRoot =
            binaryDir
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // *.xctest
            .deletingLastPathComponent()  // <bin>
        let built = binRoot.appendingPathComponent("mlx.metallib")
        guard FileManager.default.fileExists(atPath: built.path) else {
            throw XCTSkip("mlx.metallib not found at \(built.path). Run scripts/build_mlx_metallib.sh first.")
        }

        _ = try? FileManager.default.removeItem(at: colocated)
        try FileManager.default.copyItem(at: built, to: colocated)
    }
}
