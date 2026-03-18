import CoreGraphics
import CoreImage
import Foundation

public struct VisionLumaContrastStretchOptions: Sendable, Codable, Equatable {
    public var maxAnalysisDimension: Int
    public var ignoreBorderFraction: Double
    public var lowerPercentile: Double
    public var upperPercentile: Double
    /// Strength in `[0, 1]` where `0` is no-op and `1` maps the chosen percentile range toward `[0, 1]`.
    public var strength: Double
    /// Minimum `(pHigh - pLow)` range in luma (0-255) required to consider applying the stretch.
    public var minLumaRange: Double
    /// Minimum scale required to return a proposal (values below this are treated as no-op).
    public var minScale: Double
    /// Maximum allowed scale to avoid extreme amplification.
    public var maxScale: Double

    public init(
        maxAnalysisDimension: Int = 512,
        ignoreBorderFraction: Double = 0.04,
        lowerPercentile: Double = 0.02,
        upperPercentile: Double = 0.98,
        strength: Double = 0.65,
        minLumaRange: Double = 18,
        minScale: Double = 1.05,
        maxScale: Double = 1.60
    ) {
        self.maxAnalysisDimension = maxAnalysisDimension
        self.ignoreBorderFraction = ignoreBorderFraction
        self.lowerPercentile = lowerPercentile
        self.upperPercentile = upperPercentile
        self.strength = strength
        self.minLumaRange = minLumaRange
        self.minScale = minScale
        self.maxScale = maxScale
    }
}

public struct VisionLumaContrastStretchMetrics: Sendable, Codable, Equatable {
    public var analysisWidth: Int
    public var analysisHeight: Int
    public var lumaMean: Double
    public var lumaStd: Double
    public var lumaLowPercentile: Int
    public var lumaHighPercentile: Int
    public var lumaRange: Double
    public var strength: Double
    public var scale: Double
    public var bias: Double

    public init(
        analysisWidth: Int,
        analysisHeight: Int,
        lumaMean: Double,
        lumaStd: Double,
        lumaLowPercentile: Int,
        lumaHighPercentile: Int,
        lumaRange: Double,
        strength: Double,
        scale: Double,
        bias: Double
    ) {
        self.analysisWidth = analysisWidth
        self.analysisHeight = analysisHeight
        self.lumaMean = lumaMean
        self.lumaStd = lumaStd
        self.lumaLowPercentile = lumaLowPercentile
        self.lumaHighPercentile = lumaHighPercentile
        self.lumaRange = lumaRange
        self.strength = strength
        self.scale = scale
        self.bias = bias
    }
}

public struct VisionLumaContrastStretchProposal: Sendable, Codable, Equatable {
    /// Per-channel linear scale applied in RGB space (0-1 float domain).
    public var scale: Double
    /// Per-channel bias applied in RGB space (0-1 float domain).
    public var bias: Double
    /// Heuristic confidence in `[0, 1]`.
    public var confidence: Double
    public var metrics: VisionLumaContrastStretchMetrics

    public init(scale: Double, bias: Double, confidence: Double, metrics: VisionLumaContrastStretchMetrics) {
        self.scale = scale
        self.bias = bias
        self.confidence = confidence
        self.metrics = metrics
    }
}

public enum VisionLumaContrastStretchError: Error, Sendable, Equatable {
    case invalidProposal
}

extension VisionIO {
    /// Propose a conservative global contrast stretch based on luma percentiles.
    ///
    /// - Note: This returns a *proposal* only; callers should gate application using the returned confidence and
    ///   their own safety checks (crop size, task type, etc.).
    public static func proposeLumaContrastStretch(
        for image: CIImage,
        options: VisionLumaContrastStretchOptions = .init()
    ) throws -> VisionLumaContrastStretchProposal? {
        let analysis = try VisionRaster.renderRGBA8(
            image,
            maxDimension: options.maxAnalysisDimension,
            useSoftwareRenderer: true
        )
        return proposeLumaContrastStretch(for: analysis, options: options)
    }

    public static func applyLumaContrastStretch(
        _ image: CIImage,
        proposal: VisionLumaContrastStretchProposal
    ) throws -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        guard proposal.scale.isFinite, proposal.bias.isFinite, proposal.scale > 0 else {
            throw VisionLumaContrastStretchError.invalidProposal
        }

        let rgba = try VisionRaster.renderRGBA8(image)
        var data = Data(count: rgba.data.count)

        let scale = proposal.scale
        let bias = proposal.bias * 255.0
        let pixelCount = rgba.width * rgba.height

        rgba.data.withUnsafeBytes { srcRaw in
            data.withUnsafeMutableBytes { dstRaw in
                guard
                    let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }

                for i in 0..<pixelCount {
                    let idx = i * 4
                    let r = Double(src[idx])
                    let g = Double(src[idx + 1])
                    let b = Double(src[idx + 2])

                    dst[idx] = clampUInt8(Int((r * scale + bias).rounded()))
                    dst[idx + 1] = clampUInt8(Int((g * scale + bias).rounded()))
                    dst[idx + 2] = clampUInt8(Int((b * scale + bias).rounded()))
                    dst[idx + 3] = src[idx + 3]
                }
            }
        }

        let bytesPerRow = rgba.width * 4
        let size = CGSize(width: rgba.width, height: rgba.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = CIImage(
            bitmapData: data,
            bytesPerRow: bytesPerRow,
            size: size,
            format: .RGBA8,
            colorSpace: colorSpace
        )

        let translated = bitmap.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return translated.cropped(to: extent)
    }

    static func proposeLumaContrastStretch(
        for rgba: RGBA8Image,
        options: VisionLumaContrastStretchOptions
    ) -> VisionLumaContrastStretchProposal? {
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

        var hist = Array(repeating: 0, count: 256)
        var total = 0
        var sum = 0.0
        var sumSq = 0.0

        rgba.data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in y0..<y1 {
                let rowBase = y * w * 4
                for x in x0..<x1 {
                    let idx = rowBase + x * 4
                    let r = Int(base[idx])
                    let g = Int(base[idx + 1])
                    let b = Int(base[idx + 2])

                    // Rec. 709 luma approximation: 0.2126 R + 0.7152 G + 0.0722 B.
                    let luma = (54 * r + 183 * g + 19 * b) >> 8
                    hist[luma] += 1
                    total += 1
                    sum += Double(luma)
                    sumSq += Double(luma * luma)
                }
            }
        }

        guard total > 0 else { return nil }

        let mean = sum / Double(total)
        let variance = max(0.0, sumSq / Double(total) - mean * mean)
        let std = sqrt(variance)

        let lowerP = max(0.0, min(options.lowerPercentile, 0.49))
        let upperP = max(0.51, min(options.upperPercentile, 1.0))
        let lowTarget = Int((Double(total - 1) * lowerP).rounded(.down))
        let highTarget = Int((Double(total - 1) * upperP).rounded(.down))

        var lowLuma = 0
        var highLuma = 255

        var cumulative = 0
        for i in 0..<256 {
            cumulative += hist[i]
            if cumulative > lowTarget {
                lowLuma = i
                break
            }
        }

        cumulative = 0
        for i in 0..<256 {
            cumulative += hist[i]
            if cumulative > highTarget {
                highLuma = i
                break
            }
        }

        if highLuma < lowLuma {
            swap(&lowLuma, &highLuma)
        }

        let lumaRange = Double(highLuma - lowLuma)
        guard lumaRange >= options.minLumaRange else { return nil }

        let lowNorm = Double(lowLuma) / 255.0
        let highNorm = Double(highLuma) / 255.0
        let rangeNorm = max(highNorm - lowNorm, 1e-6)

        let strength = max(0.0, min(options.strength, 1.0))
        let lowOut = lowNorm * (1.0 - strength)
        let highOut = highNorm + (1.0 - highNorm) * strength

        var scale = (highOut - lowOut) / rangeNorm
        scale = min(max(scale, 0.0), max(options.maxScale, 1.0))

        guard scale >= options.minScale else { return nil }

        let bias = lowOut - lowNorm * scale
        let confidenceDenom = max(options.maxScale - 1.0, 1e-6)
        let confidence = min(max((scale - 1.0) / confidenceDenom, 0.0), 1.0)

        let metrics = VisionLumaContrastStretchMetrics(
            analysisWidth: w,
            analysisHeight: h,
            lumaMean: mean,
            lumaStd: std,
            lumaLowPercentile: lowLuma,
            lumaHighPercentile: highLuma,
            lumaRange: lumaRange,
            strength: strength,
            scale: scale,
            bias: bias
        )

        return VisionLumaContrastStretchProposal(scale: scale, bias: bias, confidence: confidence, metrics: metrics)
    }
}

@inline(__always)
private func clampUInt8(_ value: Int) -> UInt8 {
    UInt8(Swift.min(Swift.max(value, 0), 255))
}
