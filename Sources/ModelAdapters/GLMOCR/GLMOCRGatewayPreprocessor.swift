import CoreImage
import Foundation
import VLMRuntimeKit

enum GLMOCRGatewayPreprocessor {
    static func applyPageGatewayPreprocessing(_ image: CIImage, sourceURL: URL) throws -> CIImage {
        var output = image
        output = try applyPagePerspectiveRectificationIfEnabled(output, sourceURL: sourceURL)
        output = try applyPageBorderCleanupIfEnabled(output, sourceURL: sourceURL)
        return output
    }

    private static func applyPageBorderCleanupIfEnabled(_ image: CIImage, sourceURL: URL) throws -> CIImage {
        let env = ProcessInfo.processInfo.environment
        guard parseBool(env["GLMOCR_GATEWAY_BORDER_CLEANUP"]) == true else { return image }
        guard sourceURL.pathExtension.lowercased() != "pdf" else { return image }

        var options = VisionBorderCleanupOptions()
        if let maxDim = parseInt(env["GLMOCR_GATEWAY_BORDER_CLEANUP_MAX_ANALYSIS_DIM"]), maxDim > 0 {
            options.maxAnalysisDimension = maxDim
        }

        let minConfidence = parseDouble(env["GLMOCR_GATEWAY_BORDER_CLEANUP_MIN_CONFIDENCE"]) ?? 0.60
        guard let proposal = try VisionIO.proposeBorderCleanupCrop(for: image, options: options) else {
            return image
        }
        guard proposal.confidence >= minConfidence else { return image }

        let mode = normalizedNonEmpty(env["GLMOCR_GATEWAY_BORDER_CLEANUP_MODE"])?.lowercased() ?? "mask"
        let cleaned: CIImage =
            switch mode {
            case "crop":
                try VisionIO.applyBorderCleanupCrop(image, proposal: proposal)
            default:
                try VisionIO.applyBorderCleanupMask(image, proposal: proposal, fillColor: .white)
            }

        if let dir = normalizedNonEmpty(env["GLMOCR_GATEWAY_ARTIFACT_DIR"]) {
            try writeBorderCleanupArtifacts(
                original: image,
                cleaned: cleaned,
                proposal: proposal,
                sourceURL: sourceURL,
                artifactsDir: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).standardizedFileURL
            )
        }

        return cleaned
    }

    private static func applyPagePerspectiveRectificationIfEnabled(_ image: CIImage, sourceURL: URL) throws -> CIImage {
        let env = ProcessInfo.processInfo.environment
        guard parseBool(env["GLMOCR_GATEWAY_PERSPECTIVE_RECTIFY"]) == true else { return image }
        guard sourceURL.pathExtension.lowercased() != "pdf" else { return image }

        var options = VisionDocumentRectificationOptions()
        if let maxDim = parseInt(env["GLMOCR_GATEWAY_PERSPECTIVE_MAX_ANALYSIS_DIM"]), maxDim > 0 {
            options.maxAnalysisDimension = maxDim
        }
        if let minArea = parseDouble(env["GLMOCR_GATEWAY_PERSPECTIVE_MIN_AREA_FRACTION"]) {
            options.minAreaFraction = minArea
        }
        if let maxArea = parseDouble(env["GLMOCR_GATEWAY_PERSPECTIVE_MAX_AREA_FRACTION"]) {
            options.maxAreaFraction = maxArea
        }

        let minConfidence = parseDouble(env["GLMOCR_GATEWAY_PERSPECTIVE_MIN_CONFIDENCE"]) ?? 0.60
        guard let proposal = try VisionIO.proposeDocumentRectification(for: image, options: options) else {
            return image
        }
        guard proposal.confidence >= minConfidence else { return image }

        let rectified = try VisionIO.applyDocumentRectification(image, proposal: proposal)

        if let dir = normalizedNonEmpty(env["GLMOCR_GATEWAY_ARTIFACT_DIR"]) {
            try writePerspectiveRectificationArtifacts(
                original: image,
                rectified: rectified,
                proposal: proposal,
                sourceURL: sourceURL,
                artifactsDir: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).standardizedFileURL
            )
        }

        return rectified
    }

    private static func writeBorderCleanupArtifacts(
        original: CIImage,
        cleaned: CIImage,
        proposal: VisionBorderCleanupProposal,
        sourceURL: URL,
        artifactsDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let originalURL = artifactsDir.appendingPathComponent("\(baseName)_gateway_original.jpg")
        let cleanedURL = artifactsDir.appendingPathComponent("\(baseName)_gateway_border_cleaned.jpg")
        let proposalURL = artifactsDir.appendingPathComponent("\(baseName)_gateway_border_cleanup.json")

        try VisionIO.writeJPEG(original, to: originalURL, quality: 0.92)
        try VisionIO.writeJPEG(cleaned, to: cleanedURL, quality: 0.92)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(BorderCleanupArtifactPayload(sourceFile: baseName, proposal: proposal))
        try data.write(to: proposalURL)
    }

    private static func writePerspectiveRectificationArtifacts(
        original: CIImage,
        rectified: CIImage,
        proposal: VisionDocumentRectificationProposal,
        sourceURL: URL,
        artifactsDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let originalURL = artifactsDir.appendingPathComponent("\(baseName)_gateway_rectify_original.jpg")
        let rectifiedURL = artifactsDir.appendingPathComponent("\(baseName)_gateway_rectify_rectified.jpg")
        let proposalURL = artifactsDir.appendingPathComponent("\(baseName)_gateway_rectify_proposal.json")

        try VisionIO.writeJPEG(original, to: originalURL, quality: 0.92)
        try VisionIO.writeJPEG(rectified, to: rectifiedURL, quality: 0.92)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PerspectiveRectifyArtifactPayload(sourceFile: baseName, proposal: proposal))
        try data.write(to: proposalURL)
    }

    private static func parseBool(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            true
        case "0", "false", "no", "off":
            false
        default:
            nil
        }
    }

    private static func parseInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseDouble(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private struct BorderCleanupArtifactPayload: Encodable {
    var sourceFile: String
    var proposal: VisionBorderCleanupProposal

    enum CodingKeys: String, CodingKey {
        case sourceFile = "source_file"
        case proposal
    }
}

private struct PerspectiveRectifyArtifactPayload: Encodable {
    var sourceFile: String
    var proposal: VisionDocumentRectificationProposal

    enum CodingKeys: String, CodingKey {
        case sourceFile = "source_file"
        case proposal
    }
}
