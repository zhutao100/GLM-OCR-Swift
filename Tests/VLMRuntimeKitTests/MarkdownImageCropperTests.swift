import CoreImage
import Foundation
import VLMRuntimeKit
import XCTest

final class MarkdownImageCropperTests: XCTestCase {
    func testExtractImageRefs_parsesPageAndBBox() throws {
        let md = """
        Title

        ![](page=0,bbox=[57, 199, 884, 444])

        ![](page=12,bbox=[1,2,3,4])
        """

        let refs = MarkdownImageCropper.extractImageRefs(md)
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs[0].pageIndex, 0)
        XCTAssertEqual(refs[0].bbox, OCRNormalizedBBox(x1: 57, y1: 199, x2: 884, y2: 444))
        XCTAssertEqual(refs[0].originalTag, "![](page=0,bbox=[57, 199, 884, 444])")

        XCTAssertEqual(refs[1].pageIndex, 12)
        XCTAssertEqual(refs[1].bbox, OCRNormalizedBBox(x1: 1, y1: 2, x2: 3, y2: 4))
        XCTAssertEqual(refs[1].originalTag, "![](page=12,bbox=[1,2,3,4])")
    }

    func testCropAndReplaceImages_writesJPEGs_andReplacesTags() throws {
        let md = """
        ![](page=0,bbox=[0, 0, 500, 500])

        ![](page=0,bbox=[500, 500, 1000, 1000])
        """

        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("md_cropper_\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: tempDir) }
        let imgsDir = tempDir.appendingPathComponent("imgs")

        let (out, saved) = try MarkdownImageCropper.cropAndReplaceImages(
            markdown: md,
            pageImages: [image],
            outputDir: imgsDir,
            imagePrefix: "cropped"
        )

        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved[1].path))
        XCTAssertTrue(out.contains("![Image 0-0](imgs/cropped_page0_idx0.jpg)"))
        XCTAssertTrue(out.contains("![Image 0-1](imgs/cropped_page0_idx1.jpg)"))
        XCTAssertFalse(out.contains("![](page="))
    }
}
