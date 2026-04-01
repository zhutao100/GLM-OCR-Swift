import CoreImage
import Foundation

public struct VisionMonochromeThresholdHeuristicsOptions: Sendable, Codable, Equatable {
    public var maxAnalysisDimension: Int
    public var ignoreBorderFraction: Double
    /// Upper bound for mean chroma in `[0, 1]` where `0` is perfectly gray.
    public var maxChromaMean: Double
    /// Upper bound for luma standard deviation (0-255) for which thresholding is considered plausible.
    public var maxLumaStd: Double

    public init(
        maxAnalysisDimension: Int = 384,
        ignoreBorderFraction: Double = 0.04,
        maxChromaMean: Double = 0.08,
        maxLumaStd: Double = 60
    ) {
        self.maxAnalysisDimension = maxAnalysisDimension
        self.ignoreBorderFraction = ignoreBorderFraction
        self.maxChromaMean = maxChromaMean
        self.maxLumaStd = maxLumaStd
    }
}

public struct VisionMonochromeThresholdMetrics: Sendable, Codable, Equatable {
    public var analysisWidth: Int
    public var analysisHeight: Int
    public var chromaMean: Double
    public var lumaMean: Double
    public var lumaStd: Double

    public init(analysisWidth: Int, analysisHeight: Int, chromaMean: Double, lumaMean: Double, lumaStd: Double) {
        self.analysisWidth = analysisWidth
        self.analysisHeight = analysisHeight
        self.chromaMean = chromaMean
        self.lumaMean = lumaMean
        self.lumaStd = lumaStd
    }
}

public struct VisionMonochromeThresholdProposal: Sendable, Codable, Equatable {
    public var confidence: Double
    public var metrics: VisionMonochromeThresholdMetrics

    public init(confidence: Double, metrics: VisionMonochromeThresholdMetrics) {
        self.confidence = confidence
        self.metrics = metrics
    }
}

public enum VisionMonochromeThresholdMode: String, Sendable, Codable {
    case otsu
    case fixed
}

public enum VisionMonochromeMorphology: String, Sendable, Codable {
    case none
    case open
    case close
}

public struct VisionMonochromeThresholdApplyOptions: Sendable, Codable, Equatable {
    public var mode: VisionMonochromeThresholdMode
    public var fixedThreshold: Double
    public var morphology: VisionMonochromeMorphology
    public var morphologyRadius: Double

    public init(
        mode: VisionMonochromeThresholdMode = .otsu,
        fixedThreshold: Double = 0.50,
        morphology: VisionMonochromeMorphology = .none,
        morphologyRadius: Double = 1.0
    ) {
        self.mode = mode
        self.fixedThreshold = fixedThreshold
        self.morphology = morphology
        self.morphologyRadius = morphologyRadius
    }
}

public enum VisionMonochromeThresholdError: Error, Sendable, Equatable {
    case missingFixedThresholdFilter
    case cannotThreshold
    case missingMorphologyMinimumFilter
    case missingMorphologyMaximumFilter
    case cannotMorphology
}

extension VisionIO {
    /// Propose whether a monochrome threshold branch is likely safe to try.
    ///
    /// This currently gates on:
    /// - low chroma (near-monochrome inputs)
    /// - low-to-moderate luma std (avoid applying to already high-contrast text/code crops)
    public static func proposeMonochromeThreshold(
        for image: CIImage,
        options: VisionMonochromeThresholdHeuristicsOptions = .init()
    ) throws -> VisionMonochromeThresholdProposal? {
        let analysis = try VisionRaster.renderRGBA8(
            image,
            maxDimension: options.maxAnalysisDimension,
            useSoftwareRenderer: true
        )
        return proposeMonochromeThreshold(for: analysis, options: options)
    }

    public static func applyMonochromeThreshold(
        _ image: CIImage,
        options: VisionMonochromeThresholdApplyOptions = .init()
    ) throws -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        let threshold: Double
        switch options.mode {
        case .otsu:
            threshold = try estimateOtsuThresholdNormalized(for: image, maxAnalysisDimension: 512)
        case .fixed:
            threshold = max(0.0, min(options.fixedThreshold, 1.0))
        }

        guard let thresholdFilter = CIFilter(name: "CIColorThreshold") else {
            throw VisionMonochromeThresholdError.missingFixedThresholdFilter
        }
        thresholdFilter.setValue(image, forKey: kCIInputImageKey)
        thresholdFilter.setValue(threshold, forKey: "inputThreshold")
        guard let thresholded = thresholdFilter.outputImage else {
            throw VisionMonochromeThresholdError.cannotThreshold
        }

        let cropped = thresholded.cropped(to: extent)
        guard options.morphology != .none, options.morphologyRadius > 0 else { return cropped }

        let radius = max(0.0, options.morphologyRadius)
        guard let minFilter = CIFilter(name: "CIMorphologyMinimum") else {
            throw VisionMonochromeThresholdError.missingMorphologyMinimumFilter
        }
        guard let maxFilter = CIFilter(name: "CIMorphologyMaximum") else {
            throw VisionMonochromeThresholdError.missingMorphologyMaximumFilter
        }

        func applyMin(_ input: CIImage) -> CIImage? {
            minFilter.setValue(input, forKey: kCIInputImageKey)
            minFilter.setValue(radius, forKey: "inputRadius")
            return minFilter.outputImage
        }

        func applyMax(_ input: CIImage) -> CIImage? {
            maxFilter.setValue(input, forKey: kCIInputImageKey)
            maxFilter.setValue(radius, forKey: "inputRadius")
            return maxFilter.outputImage
        }

        let morphed: CIImage? =
            switch options.morphology {
            case .open:
                applyMin(cropped).flatMap(applyMax)
            case .close:
                applyMax(cropped).flatMap(applyMin)
            case .none:
                cropped
            }

        guard let morphed else { throw VisionMonochromeThresholdError.cannotMorphology }
        return morphed.cropped(to: extent)
    }

    static func proposeMonochromeThreshold(
        for rgba: RGBA8Image,
        options: VisionMonochromeThresholdHeuristicsOptions
    ) -> VisionMonochromeThresholdProposal? {
        let w = rgba.width
        let h = rgba.height
        guard w > 0, h > 0 else { return nil }

        let ignoreBorder = max(0, min(options.ignoreBorderFraction, 0.45))
        let borderX = max(Int((Double(w) * ignoreBorder).rounded(.toNearestOrAwayFromZero)), 0)
        let borderY = max(Int((Double(h) * ignoreBorder).rounded(.toNearestOrAwayFromZero)), 0)

        let x0 = min(borderX, max(w - 1, 0))
        let y0 = min(borderY, max(h - 1, 0))
        let x1 = max(w - borderX, x0 + 1)
        let y1 = max(h - borderY, y0 + 1)

        var total = 0
        var chromaSum = 0.0
        var lumaSum = 0.0
        var lumaSumSq = 0.0

        rgba.data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in y0..<y1 {
                let rowBase = y * w * 4
                for x in x0..<x1 {
                    let idx = rowBase + x * 4
                    let r = Int(base[idx])
                    let g = Int(base[idx + 1])
                    let b = Int(base[idx + 2])

                    let drg = abs(r - g)
                    let dgb = abs(g - b)
                    let dbr = abs(b - r)
                    chromaSum += Double(drg + dgb + dbr)

                    let luma = (54 * r + 183 * g + 19 * b) >> 8
                    lumaSum += Double(luma)
                    lumaSumSq += Double(luma * luma)
                    total += 1
                }
            }
        }

        guard total > 0 else { return nil }

        let chromaMean = chromaSum / (Double(total) * 3.0 * 255.0)
        let lumaMean = lumaSum / Double(total)
        let variance = max(0.0, lumaSumSq / Double(total) - lumaMean * lumaMean)
        let lumaStd = sqrt(variance)

        let chromaDenom = max(options.maxChromaMean, 1e-6)
        let stdDenom = max(options.maxLumaStd, 1e-6)
        let chromaScore = clamp01(1.0 - chromaMean / chromaDenom)
        let stdScore = clamp01(1.0 - lumaStd / stdDenom)
        let confidence = clamp01(chromaScore * stdScore)

        let metrics = VisionMonochromeThresholdMetrics(
            analysisWidth: w,
            analysisHeight: h,
            chromaMean: chromaMean,
            lumaMean: lumaMean,
            lumaStd: lumaStd
        )
        return VisionMonochromeThresholdProposal(confidence: confidence, metrics: metrics)
    }
}

@inline(__always)
private func clamp01(_ value: Double) -> Double {
    min(max(value, 0.0), 1.0)
}

private func estimateOtsuThresholdNormalized(for image: CIImage, maxAnalysisDimension: Int) throws -> Double {
    // Note: useSoftwareRenderer=false here because some Core Image filter graphs (notably mask blends from polygon crops)
    // can crash under the software renderer on macOS for certain inputs.
    let analysis = try VisionRaster.renderRGBA8(image, maxDimension: maxAnalysisDimension, useSoftwareRenderer: false)
    let w = analysis.width
    let h = analysis.height
    guard w > 0, h > 0 else { return 0.5 }

    var hist = Array(repeating: 0, count: 256)
    var total = 0

    analysis.data.withUnsafeBytes { rawBuf in
        guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let pixelCount = w * h
        for i in 0..<pixelCount {
            let idx = i * 4
            let r = Int(base[idx])
            let g = Int(base[idx + 1])
            let b = Int(base[idx + 2])
            let luma = (54 * r + 183 * g + 19 * b) >> 8
            hist[luma] += 1
            total += 1
        }
    }

    guard total > 0 else { return 0.5 }

    var sumAll = 0.0
    for i in 0..<256 {
        sumAll += Double(i * hist[i])
    }

    var sumB = 0.0
    var wB = 0.0
    var maxBetween = -1.0
    var bestThreshold = 128

    for t in 0..<256 {
        wB += Double(hist[t])
        if wB <= 0 { continue }

        let wF = Double(total) - wB
        if wF <= 0 { break }

        sumB += Double(t * hist[t])
        let mB = sumB / wB
        let mF = (sumAll - sumB) / wF
        let between = wB * wF * (mB - mF) * (mB - mF)

        if between > maxBetween {
            maxBetween = between
            bestThreshold = t
        }
    }

    return Double(bestThreshold) / 255.0
}
