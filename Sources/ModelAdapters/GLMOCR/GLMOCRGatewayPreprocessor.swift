import CoreImage
import Foundation
import VLMRuntimeKit

enum GLMOCRGatewayPreprocessor {
    static func applyPageGatewayPreprocessing(_ image: CIImage, sourceURL: URL) throws -> CIImage {
        var output = image
        output = try applyPagePerspectiveRectificationIfEnabled(output, sourceURL: sourceURL)
        output = try applyPageBorderCleanupIfEnabled(output, sourceURL: sourceURL)
        output = try applyPageDeskewIfEnabled(output, sourceURL: sourceURL)
        return output
    }

    static func applyOCRInputGatewayPreprocessing(_ image: CIImage) throws -> CIImage {
        var output = image
        output = try applyOCRDeskewIfEnabled(output)
        output = try applyOCRDenoiseIfEnabled(output)
        output = try applyOCRContrastStretchIfEnabled(output)
        output = try applyOCRMonochromeIfEnabled(output)
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

    private static func applyPageDeskewIfEnabled(_ image: CIImage, sourceURL: URL) throws -> CIImage {
        let env = ProcessInfo.processInfo.environment
        guard parseBool(env["GLMOCR_GATEWAY_DESKEW"]) == true else { return image }
        guard deskewStage(env: env) == .page else { return image }
        guard sourceURL.pathExtension.lowercased() != "pdf" else { return image }

        let options = parseDeskewOptions(env: env)

        guard let estimate = try VisionIO.estimateDeskewAngle(for: image, options: options) else {
            return image
        }

        let deskewed = try VisionIO.applyDeskew(image, angleDegrees: estimate.angleDegrees, fillColor: .white)

        if let dir = normalizedNonEmpty(env["GLMOCR_GATEWAY_ARTIFACT_DIR"]) {
            try writeDeskewArtifacts(
                original: image,
                deskewed: deskewed,
                estimate: estimate,
                sourceURL: sourceURL,
                artifactsDir: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).standardizedFileURL
            )
        }

        return deskewed
    }

    private static func applyOCRDeskewIfEnabled(_ image: CIImage) throws -> CIImage {
        let env = ProcessInfo.processInfo.environment
        guard parseBool(env["GLMOCR_GATEWAY_DESKEW"]) == true else { return image }
        guard deskewStage(env: env) == .ocr else { return image }

        let extent = image.extent.integral
        guard extent.width >= 96, extent.height >= 96 else { return image }

        let options = parseDeskewOptions(env: env)
        guard let estimate = try VisionIO.estimateDeskewAngle(for: image, options: options) else {
            return image
        }

        return try VisionIO.applyDeskew(image, angleDegrees: estimate.angleDegrees, fillColor: .white)
    }

    private static func applyOCRDenoiseIfEnabled(_ image: CIImage) throws -> CIImage {
        let env = ProcessInfo.processInfo.environment
        guard parseBool(env["GLMOCR_GATEWAY_DENOISE"]) == true else { return image }

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        let minDim = parseInt(env["GLMOCR_GATEWAY_DENOISE_MIN_DIM"]) ?? 96
        guard Int(extent.width) >= minDim, Int(extent.height) >= minDim else { return image }

        let mode = normalizedNonEmpty(env["GLMOCR_GATEWAY_DENOISE_MODE"])?.lowercased() ?? "median"
        switch mode {
        case "noise_reduction", "noise-reduction", "nr":
            var options = VisionNoiseReductionOptions()
            if let noiseLevel = parseDouble(env["GLMOCR_GATEWAY_DENOISE_NOISE_LEVEL"]), noiseLevel >= 0 {
                options.noiseLevel = noiseLevel
            }
            if let sharpness = parseDouble(env["GLMOCR_GATEWAY_DENOISE_SHARPNESS"]), sharpness >= 0 {
                options.sharpness = sharpness
            }
            return try VisionIO.applyNoiseReductionDenoise(image, options: options)
        default:
            return try VisionIO.applyMedianDenoise(image)
        }
    }

    private static func applyOCRContrastStretchIfEnabled(_ image: CIImage) throws -> CIImage {
        let env = ProcessInfo.processInfo.environment
        guard parseBool(env["GLMOCR_GATEWAY_CONTRAST"]) == true else { return image }

        let extent = image.extent.integral
        guard extent.width >= 64, extent.height >= 64 else { return image }

        var options = VisionLumaContrastStretchOptions()
        if let maxDim = parseInt(env["GLMOCR_GATEWAY_CONTRAST_MAX_ANALYSIS_DIM"]), maxDim > 0 {
            options.maxAnalysisDimension = maxDim
        }
        if let ignoreBorder = parseDouble(env["GLMOCR_GATEWAY_CONTRAST_IGNORE_BORDER_FRACTION"]), ignoreBorder >= 0 {
            options.ignoreBorderFraction = ignoreBorder
        }
        if let lowerP = parseDouble(env["GLMOCR_GATEWAY_CONTRAST_LOWER_P"]), lowerP >= 0 {
            options.lowerPercentile = lowerP
        }
        if let upperP = parseDouble(env["GLMOCR_GATEWAY_CONTRAST_UPPER_P"]), upperP >= 0 {
            options.upperPercentile = upperP
        }
        if let strength = parseDouble(env["GLMOCR_GATEWAY_CONTRAST_STRENGTH"]), strength >= 0 {
            options.strength = strength
        }
        if let minRange = parseDouble(env["GLMOCR_GATEWAY_CONTRAST_MIN_LUMA_RANGE"]), minRange >= 0 {
            options.minLumaRange = minRange
        }
        if let minScale = parseDouble(env["GLMOCR_GATEWAY_CONTRAST_MIN_SCALE"]), minScale > 0 {
            options.minScale = minScale
        }
        if let maxScale = parseDouble(env["GLMOCR_GATEWAY_CONTRAST_MAX_SCALE"]), maxScale > 0 {
            options.maxScale = maxScale
        }

        let minConfidence = parseDouble(env["GLMOCR_GATEWAY_CONTRAST_MIN_CONFIDENCE"]) ?? 0.25
        guard let proposal = try VisionIO.proposeLumaContrastStretch(for: image, options: options) else {
            return image
        }
        guard proposal.confidence >= minConfidence else { return image }

        return try VisionIO.applyLumaContrastStretch(image, proposal: proposal)
    }

    private static func applyOCRMonochromeIfEnabled(_ image: CIImage) throws -> CIImage {
        let env = ProcessInfo.processInfo.environment
        guard parseBool(env["GLMOCR_GATEWAY_MONO"]) == true else { return image }

        let extent = image.extent.integral
        guard extent.width >= 64, extent.height >= 64 else { return image }

        var heuristics = VisionMonochromeThresholdHeuristicsOptions()
        if let maxDim = parseInt(env["GLMOCR_GATEWAY_MONO_MAX_ANALYSIS_DIM"]), maxDim > 0 {
            heuristics.maxAnalysisDimension = maxDim
        }
        if let ignoreBorder = parseDouble(env["GLMOCR_GATEWAY_MONO_IGNORE_BORDER_FRACTION"]), ignoreBorder >= 0 {
            heuristics.ignoreBorderFraction = ignoreBorder
        }
        if let maxChroma = parseDouble(env["GLMOCR_GATEWAY_MONO_MAX_CHROMA_MEAN"]), maxChroma >= 0 {
            heuristics.maxChromaMean = maxChroma
        }
        if let maxStd = parseDouble(env["GLMOCR_GATEWAY_MONO_MAX_LUMA_STD"]), maxStd >= 0 {
            heuristics.maxLumaStd = maxStd
        }

        let minConfidence = parseDouble(env["GLMOCR_GATEWAY_MONO_MIN_CONFIDENCE"]) ?? 0.60
        guard let proposal = try VisionIO.proposeMonochromeThreshold(for: image, options: heuristics) else {
            return image
        }
        guard proposal.confidence >= minConfidence else { return image }

        var applyOptions = VisionMonochromeThresholdApplyOptions()
        if let modeRaw = normalizedNonEmpty(env["GLMOCR_GATEWAY_MONO_MODE"])?.lowercased() {
            switch modeRaw {
            case "fixed", "threshold":
                applyOptions.mode = .fixed
            default:
                applyOptions.mode = .otsu
            }
        }
        if let t = parseDouble(env["GLMOCR_GATEWAY_MONO_THRESHOLD"]) {
            applyOptions.fixedThreshold = t
        }
        if let morphRaw = normalizedNonEmpty(env["GLMOCR_GATEWAY_MONO_MORPH"])?.lowercased() {
            switch morphRaw {
            case "open":
                applyOptions.morphology = .open
            case "close":
                applyOptions.morphology = .close
            default:
                applyOptions.morphology = .none
            }
        }
        if let radius = parseDouble(env["GLMOCR_GATEWAY_MONO_MORPH_RADIUS"]), radius >= 0 {
            applyOptions.morphologyRadius = radius
        }

        return try VisionIO.applyMonochromeThreshold(image, options: applyOptions)
    }

    private static func parseDeskewOptions(env: [String: String]) -> VisionDeskewOptions {
        var options = VisionDeskewOptions()
        if let maxDim = parseInt(env["GLMOCR_GATEWAY_DESKEW_MAX_ANALYSIS_DIM"]), maxDim > 0 {
            options.maxAnalysisDimension = maxDim
        }
        if let maxDeg = parseDouble(env["GLMOCR_GATEWAY_DESKEW_MAX_DEG"]), maxDeg > 0 {
            options.maxAngleDegrees = maxDeg
        }
        if let step = parseDouble(env["GLMOCR_GATEWAY_DESKEW_STEP_DEG"]), step > 0 {
            options.stepDegrees = step
        }
        if let edgeThreshold = parseInt(env["GLMOCR_GATEWAY_DESKEW_EDGE_THRESHOLD"]), edgeThreshold > 0 {
            options.edgeMagnitudeThreshold = edgeThreshold
        }
        if let stride = parseInt(env["GLMOCR_GATEWAY_DESKEW_SAMPLE_STRIDE"]), stride > 0 {
            options.sampleStride = stride
        }
        if let ignoreBorder = parseDouble(env["GLMOCR_GATEWAY_DESKEW_IGNORE_BORDER_FRACTION"]), ignoreBorder >= 0 {
            options.ignoreBorderFraction = ignoreBorder
        }
        if let minApply = parseDouble(env["GLMOCR_GATEWAY_DESKEW_MIN_APPLY_DEG"]), minApply >= 0 {
            options.minApplyAngleDegrees = minApply
        }
        if let minConf = parseDouble(env["GLMOCR_GATEWAY_DESKEW_MIN_CONFIDENCE"]), minConf >= 0 {
            options.minConfidence = minConf
        }
        return options
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

    private static func writeDeskewArtifacts(
        original: CIImage,
        deskewed: CIImage,
        estimate: VisionDeskewEstimate,
        sourceURL: URL,
        artifactsDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let originalURL = artifactsDir.appendingPathComponent("\(baseName)_gateway_deskew_original.jpg")
        let deskewedURL = artifactsDir.appendingPathComponent("\(baseName)_gateway_deskew_deskewed.jpg")
        let estimateURL = artifactsDir.appendingPathComponent("\(baseName)_gateway_deskew_estimate.json")

        try VisionIO.writeJPEG(original, to: originalURL, quality: 0.92)
        try VisionIO.writeJPEG(deskewed, to: deskewedURL, quality: 0.92)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(DeskewArtifactPayload(sourceFile: baseName, estimate: estimate))
        try data.write(to: estimateURL)
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

    private enum DeskewStage: String {
        case page
        case ocr
    }

    private static func deskewStage(env: [String: String]) -> DeskewStage {
        guard let raw = normalizedNonEmpty(env["GLMOCR_GATEWAY_DESKEW_STAGE"])?.lowercased() else { return .ocr }
        return DeskewStage(rawValue: raw) ?? .ocr
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

private struct DeskewArtifactPayload: Encodable {
    var sourceFile: String
    var estimate: VisionDeskewEstimate

    enum CodingKeys: String, CodingKey {
        case sourceFile = "source_file"
        case estimate
    }
}
