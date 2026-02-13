import CoreImage
import DocLayoutAdapter
import Foundation
import GLMOCRAdapter
import VLMRuntimeKit
import XCTest

final class LayoutExamplesParityIntegrationTests: XCTestCase {
    private struct StaticModelStore: ModelStore {
        var foldersByModelID: [String: URL]

        func resolveSnapshot(
            _ request: ModelSnapshotRequest,
            downloadBase _: URL?,
            progress _: (@Sendable (Progress) -> Void)?
        ) async throws -> URL {
            guard let folder = foldersByModelID[request.modelID] else {
                throw XCTSkip("No snapshot folder configured for modelID='\(request.modelID)'.")
            }
            return folder
        }
    }

    func testGLM45V_Page1_layoutOutput_matchesExamples() async throws {
        guard ProcessInfo.processInfo.environment["GLMOCR_RUN_EXAMPLES"] == "1" else {
            throw XCTSkip("Set GLMOCR_RUN_EXAMPLES=1 to enable this end-to-end examples parity test.")
        }
        guard let glmModelFolder = GLMOCRTestEnv.modelFolderURL else {
            throw XCTSkip("Set GLMOCR_SNAPSHOT_PATH to a local GLM-OCR HF snapshot folder to enable this test.")
        }
        guard let rawLayoutFolder = ProcessInfo.processInfo.environment["LAYOUT_SNAPSHOT_PATH"], !rawLayoutFolder.isEmpty else {
            throw XCTSkip("Set LAYOUT_SNAPSHOT_PATH to a local PP-DocLayout-V3 HF snapshot folder to enable this test.")
        }

        let layoutFolder = URL(fileURLWithPath: (rawLayoutFolder as NSString).expandingTildeInPath).standardizedFileURL

        try ensureMLXMetalLibraryColocated(for: Self.self)

        let repoRoot = Self.repoRootURL()
        let sourcePDF = repoRoot.appendingPathComponent("examples/source/GLM-4.5V_Page_1.pdf")
        let expectedMDURL = repoRoot.appendingPathComponent("examples/result/GLM-4.5V_Page_1/GLM-4.5V_Page_1.md")
        let expectedJSONURL = repoRoot.appendingPathComponent("examples/result/GLM-4.5V_Page_1/GLM-4.5V_Page_1.json")

        let expectedMarkdown = try String(contentsOf: expectedMDURL, encoding: .utf8)
        let expectedJSON = try JSONDecoder().decode(OCRBlockListExport.self, from: Data(contentsOf: expectedJSONURL))

        let store = StaticModelStore(
            foldersByModelID: [
                GLMOCRDefaults.modelID: glmModelFolder,
                PPDocLayoutV3Defaults.modelID: layoutFolder,
            ]
        )

        let pipeline = GLMOCRLayoutPipeline(
            modelID: GLMOCRDefaults.modelID,
            revision: GLMOCRDefaults.revision,
            downloadBase: nil,
            store: store
        )
        try await pipeline.ensureLoaded(progress: nil)

        let result = try await pipeline.recognize(
            .file(sourcePDF, page: 1),
            task: .text,
            options: .init(maxNewTokens: 2048, temperature: 0, topP: 1)
        )
        guard let document = result.document else {
            XCTFail("Layout pipeline did not produce OCRResult.document")
            return
        }

        let pageImage = try VisionIO.loadCIImage(fromPDF: sourcePDF, page: 1, dpi: 200)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("glmocr_examples_\(UUID().uuidString)")
        let imgsDir = tempDir.appendingPathComponent("imgs")

        let (actualMarkdown, saved) = try MarkdownImageCropper.cropAndReplaceImages(
            markdown: result.text,
            pageImages: [pageImage],
            outputDir: imgsDir,
            imagePrefix: "cropped"
        )

        let expectedImageCount = expectedJSON.flatMap(\.self).count(where: { $0.label == "image" })
        XCTAssertEqual(saved.count, expectedImageCount, "Expected to crop \(expectedImageCount) images.")

        let expectedImagePaths = Self.extractMarkdownImagePaths(expectedMarkdown)
        let actualImagePaths = Self.extractMarkdownImagePaths(actualMarkdown)
        XCTAssertEqual(actualImagePaths, expectedImagePaths, "Markdown image refs mismatch vs examples/result/…")
        XCTAssertFalse(actualMarkdown.contains("![](page="), "Expected placeholder image refs to be replaced.")

        let actualJSON = document.toBlockListExport()
        try Self.assertJSONParity(actual: actualJSON, expected: expectedJSON, bboxTolerance: 15)
    }

    private static func repoRootURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // GLMOCRAdapterTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private static func normalizedText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            trimmingTrailingWhitespace(String(line))
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractMarkdownImagePaths(_ markdown: String) -> [String] {
        let pattern = #"\!\[Image[^\]]*\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
        let matches = regex.matches(in: markdown, range: nsRange)

        var paths: [String] = []
        paths.reserveCapacity(matches.count)

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            guard let range = Range(match.range(at: 1), in: markdown) else { continue }
            paths.append(String(markdown[range]))
        }

        return paths
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let before = line.index(before: end)
            if line[before].isWhitespace {
                end = before
            } else {
                break
            }
        }
        return String(line[..<end])
    }

    private static func assertJSONParity(
        actual: OCRBlockListExport,
        expected: OCRBlockListExport,
        bboxTolerance: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(actual.count, expected.count, "Page count mismatch", file: file, line: line)

        for (pageIdx, (actualPage, expectedPage)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(actualPage.count, expectedPage.count, "Block count mismatch on page \(pageIdx)", file: file, line: line)

            for (blockIdx, (a, e)) in zip(actualPage, expectedPage).enumerated() {
                XCTAssertEqual(a.index, e.index, "Index mismatch on page \(pageIdx) block \(blockIdx)", file: file, line: line)
                XCTAssertEqual(a.label, e.label, "Label mismatch on page \(pageIdx) block \(blockIdx)", file: file, line: line)

                if a.label == "image" {
                    XCTAssertTrue(a.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Image blocks must have empty content", file: file, line: line)
                    XCTAssertTrue(e.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Expected image blocks must have empty content", file: file, line: line)
                } else {
                    XCTAssertFalse(a.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Text blocks must have non-empty content", file: file, line: line)
                    XCTAssertFalse(e.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Expected text blocks must have non-empty content", file: file, line: line)
                }

                XCTAssertEqual(a.bbox2d.count, 4, "Actual bbox_2d must have 4 elements", file: file, line: line)
                XCTAssertEqual(e.bbox2d.count, 4, "Expected bbox_2d must have 4 elements", file: file, line: line)

                for (coordIdx, (av, ev)) in zip(a.bbox2d, e.bbox2d).enumerated() {
                    let delta = abs(av - ev)
                    XCTAssertLessThanOrEqual(
                        delta,
                        bboxTolerance,
                        "bbox_2d mismatch on page \(pageIdx) block \(blockIdx) coord \(coordIdx): actual=\(av) expected=\(ev)",
                        file: file,
                        line: line
                    )
                }
            }
        }
    }
}
