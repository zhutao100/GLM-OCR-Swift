import CoreImage
import Foundation

public struct MarkdownImageRef: Sendable, Equatable {
    public var pageIndex: Int
    public var bbox: OCRNormalizedBBox
    public var originalTag: String

    public init(pageIndex: Int, bbox: OCRNormalizedBBox, originalTag: String) {
        self.pageIndex = pageIndex
        self.bbox = bbox
        self.originalTag = originalTag
    }
}

public enum MarkdownImageCropper {
    /// Extract `![](page=<n>,bbox=[x1, y1, x2, y2])` references from Markdown.
    ///
    /// Mirrors `glmocr/utils/markdown_utils.py`.
    public static func extractImageRefs(_ markdown: String) -> [MarkdownImageRef] {
        let pattern = #"!\[\]\(page=(\d+),bbox=(\[[\d,\s]+\])\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        let matches = regex.matches(in: markdown, range: nsRange)

        var refs: [MarkdownImageRef] = []
        refs.reserveCapacity(matches.count)

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }

            guard let fullRange = Range(match.range(at: 0), in: markdown),
                let pageRange = Range(match.range(at: 1), in: markdown),
                let bboxRange = Range(match.range(at: 2), in: markdown)
            else {
                continue
            }

            let pageStr = String(markdown[pageRange])
            guard let pageIndex = Int(pageStr) else { continue }

            let bboxStr = String(markdown[bboxRange])
            guard let bbox = parseBBox(bboxStr) else { continue }

            let originalTag = String(markdown[fullRange])
            refs.append(.init(pageIndex: pageIndex, bbox: bbox, originalTag: originalTag))
        }

        return refs
    }

    /// Crop referenced image regions and replace the placeholder tags with `![Image p-i](imgs/<file>)`.
    ///
    /// - Parameters:
    ///   - markdown: Source Markdown containing placeholder tags.
    ///   - pageImages: Page images indexed by `pageIndex`.
    ///   - outputDir: Directory to write the cropped JPEGs into (typically `<output>/imgs`).
    ///   - imagePrefix: Output filename prefix (default: `cropped`, matching `examples/reference_result/*`).
    ///
    /// - Returns: Updated markdown and the list of saved image URLs.
    public static func cropAndReplaceImages(
        markdown: String,
        pageImages: [CIImage],
        outputDir: URL,
        imagePrefix: String = "cropped",
        jpegQuality: CGFloat = 0.95
    ) throws -> (markdown: String, saved: [URL]) {
        let refs = extractImageRefs(markdown)
        guard !refs.isEmpty else { return (markdown, []) }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var resultMarkdown = markdown
        var saved: [URL] = []
        saved.reserveCapacity(refs.count)

        for (idx, ref) in refs.enumerated() {
            guard ref.pageIndex >= 0, ref.pageIndex < pageImages.count else { continue }

            let originalImage = pageImages[ref.pageIndex]
            do {
                let cropped = try VisionIO.cropRegion(
                    image: originalImage,
                    bbox: ref.bbox,
                    polygon: nil,
                    fillColor: .white
                )

                let filename = "\(imagePrefix)_page\(ref.pageIndex)_idx\(idx).jpg"
                let imageURL = outputDir.appendingPathComponent(filename)
                try VisionIO.writeJPEG(cropped, to: imageURL, quality: jpegQuality)
                saved.append(imageURL)

                let relativePath = "imgs/\(filename)"
                let newTag = "![Image \(ref.pageIndex)-\(idx)](\(relativePath))"

                if let range = resultMarkdown.range(of: ref.originalTag) {
                    resultMarkdown.replaceSubrange(range, with: newTag)
                }
            } catch {
                // Keep the original tag on failure (matches the Python behavior).
                continue
            }
        }

        return (resultMarkdown, saved)
    }
}

private func parseBBox(_ bboxString: String) -> OCRNormalizedBBox? {
    let trimmed = bboxString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 else { return nil }

    let inner = trimmed.dropFirst().dropLast()
    let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }

    let values = parts.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    guard values.count == 4 else { return nil }

    return OCRNormalizedBBox(x1: values[0], y1: values[1], x2: values[2], y2: values[3])
}
