import CoreImage
import Foundation

public enum VisionBorderTone: String, Sendable, Codable {
    case dark
    case light
}

public struct VisionBorderCleanupOptions: Sendable, Codable, Equatable {
    public var maxAnalysisDimension: Int

    public var darkMeanThreshold: Double
    public var darkStdThreshold: Double

    public var lightMeanThreshold: Double
    public var lightStdThreshold: Double

    public var minBorderFraction: Double
    public var minBorderPixels: Int
    public var maxBorderFraction: Double

    public var safetyBorderFraction: Double
    public var safetyBorderPixels: Int

    public var minCropAreaFraction: Double

    public var probeFraction: Double
    public var deltaMin: Double
    public var deltaRange: Double

    public init(
        maxAnalysisDimension: Int = 512,
        darkMeanThreshold: Double = 40,
        darkStdThreshold: Double = 14,
        lightMeanThreshold: Double = 238,
        lightStdThreshold: Double = 10,
        minBorderFraction: Double = 0.03,
        minBorderPixels: Int = 8,
        maxBorderFraction: Double = 0.35,
        safetyBorderFraction: Double = 0.01,
        safetyBorderPixels: Int = 4,
        minCropAreaFraction: Double = 0.60,
        probeFraction: Double = 0.05,
        deltaMin: Double = 18,
        deltaRange: Double = 42
    ) {
        self.maxAnalysisDimension = maxAnalysisDimension
        self.darkMeanThreshold = darkMeanThreshold
        self.darkStdThreshold = darkStdThreshold
        self.lightMeanThreshold = lightMeanThreshold
        self.lightStdThreshold = lightStdThreshold
        self.minBorderFraction = minBorderFraction
        self.minBorderPixels = minBorderPixels
        self.maxBorderFraction = maxBorderFraction
        self.safetyBorderFraction = safetyBorderFraction
        self.safetyBorderPixels = safetyBorderPixels
        self.minCropAreaFraction = minCropAreaFraction
        self.probeFraction = probeFraction
        self.deltaMin = deltaMin
        self.deltaRange = deltaRange
    }
}

public struct VisionBorderCleanupSideMetrics: Sendable, Codable, Equatable {
    public var thicknessPixels: Int
    public var tone: VisionBorderTone?
    public var confidence: Double

    public init(thicknessPixels: Int, tone: VisionBorderTone?, confidence: Double) {
        self.thicknessPixels = thicknessPixels
        self.tone = tone
        self.confidence = confidence
    }
}

public struct VisionBorderCleanupMetrics: Sendable, Codable, Equatable {
    public var analysisWidth: Int
    public var analysisHeight: Int
    public var left: VisionBorderCleanupSideMetrics
    public var right: VisionBorderCleanupSideMetrics
    public var top: VisionBorderCleanupSideMetrics
    public var bottom: VisionBorderCleanupSideMetrics
    public var cropAreaFraction: Double

    public init(
        analysisWidth: Int,
        analysisHeight: Int,
        left: VisionBorderCleanupSideMetrics,
        right: VisionBorderCleanupSideMetrics,
        top: VisionBorderCleanupSideMetrics,
        bottom: VisionBorderCleanupSideMetrics,
        cropAreaFraction: Double
    ) {
        self.analysisWidth = analysisWidth
        self.analysisHeight = analysisHeight
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
        self.cropAreaFraction = cropAreaFraction
    }
}

public struct VisionBorderCleanupProposal: Sendable, Codable, Equatable {
    /// Proposed content crop bbox in `[0, 1000]` normalized coordinates, with the origin at the top-left.
    public var bbox: OCRNormalizedBBox
    public var confidence: Double
    public var metrics: VisionBorderCleanupMetrics

    public init(bbox: OCRNormalizedBBox, confidence: Double, metrics: VisionBorderCleanupMetrics) {
        self.bbox = bbox
        self.confidence = confidence
        self.metrics = metrics
    }
}

extension VisionIO {
    /// Propose a border/canvas cleanup crop bbox for a page image.
    ///
    /// - Important: This is a lightweight heuristic intended for **high-confidence** dark-border and overscan cases.
    ///   Callers should treat the returned `confidence` as an input to policy gating.
    public static func proposeBorderCleanupCrop(
        for image: CIImage,
        options: VisionBorderCleanupOptions = .init()
    ) throws -> VisionBorderCleanupProposal? {
        let analysis = try VisionRaster.renderRGBA8(
            image,
            maxDimension: options.maxAnalysisDimension,
            useSoftwareRenderer: true
        )
        return proposeBorderCleanupCrop(for: analysis, options: options)
    }

    /// Apply a previously proposed border cleanup crop to the given image.
    public static func applyBorderCleanupCrop(_ image: CIImage, proposal: VisionBorderCleanupProposal) throws -> CIImage {
        try cropRegion(image: image, bbox: proposal.bbox, polygon: nil, fillColor: .white)
    }

    /// Apply a previously proposed border cleanup bbox by masking pixels outside the bbox to `fillColor`.
    ///
    /// - Note: This preserves the original image extent, which helps keep downstream geometry stable for layout mode.
    public static func applyBorderCleanupMask(
        _ image: CIImage,
        proposal: VisionBorderCleanupProposal,
        fillColor: CIColor = .white
    ) throws -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        let kept = try cropRegion(image: image, bbox: proposal.bbox, polygon: nil, fillColor: fillColor)
        let background = CIImage(color: fillColor).cropped(to: extent)
        return kept.composited(over: background).cropped(to: extent)
    }

    static func proposeBorderCleanupCrop(
        for rgba: RGBA8Image,
        options: VisionBorderCleanupOptions
    ) -> VisionBorderCleanupProposal? {
        let w = rgba.width
        let h = rgba.height
        guard w > 0, h > 0 else { return nil }

        let stats = BorderStats.compute(rgba: rgba)

        let minBorderX = max(Int((Double(w) * options.minBorderFraction).rounded(.up)), options.minBorderPixels)
        let minBorderY = max(Int((Double(h) * options.minBorderFraction).rounded(.up)), options.minBorderPixels)
        let maxBorderX = max(Int((Double(w) * options.maxBorderFraction).rounded(.down)), 0)
        let maxBorderY = max(Int((Double(h) * options.maxBorderFraction).rounded(.down)), 0)

        let left = BorderStats.detectThicknessFromStart(
            means: stats.colMean,
            stds: stats.colStd,
            tone: .dark,
            meanThreshold: options.darkMeanThreshold,
            stdThreshold: options.darkStdThreshold,
            maxThickness: maxBorderX
        )
        let leftLight = BorderStats.detectThicknessFromStart(
            means: stats.colMean,
            stds: stats.colStd,
            tone: .light,
            meanThreshold: options.lightMeanThreshold,
            stdThreshold: options.lightStdThreshold,
            maxThickness: maxBorderX
        )
        let right = BorderStats.detectThicknessFromEnd(
            means: stats.colMean,
            stds: stats.colStd,
            tone: .dark,
            meanThreshold: options.darkMeanThreshold,
            stdThreshold: options.darkStdThreshold,
            maxThickness: maxBorderX
        )
        let rightLight = BorderStats.detectThicknessFromEnd(
            means: stats.colMean,
            stds: stats.colStd,
            tone: .light,
            meanThreshold: options.lightMeanThreshold,
            stdThreshold: options.lightStdThreshold,
            maxThickness: maxBorderX
        )
        let top = BorderStats.detectThicknessFromStart(
            means: stats.rowMean,
            stds: stats.rowStd,
            tone: .dark,
            meanThreshold: options.darkMeanThreshold,
            stdThreshold: options.darkStdThreshold,
            maxThickness: maxBorderY
        )
        let topLight = BorderStats.detectThicknessFromStart(
            means: stats.rowMean,
            stds: stats.rowStd,
            tone: .light,
            meanThreshold: options.lightMeanThreshold,
            stdThreshold: options.lightStdThreshold,
            maxThickness: maxBorderY
        )
        let bottom = BorderStats.detectThicknessFromEnd(
            means: stats.rowMean,
            stds: stats.rowStd,
            tone: .dark,
            meanThreshold: options.darkMeanThreshold,
            stdThreshold: options.darkStdThreshold,
            maxThickness: maxBorderY
        )
        let bottomLight = BorderStats.detectThicknessFromEnd(
            means: stats.rowMean,
            stds: stats.rowStd,
            tone: .light,
            meanThreshold: options.lightMeanThreshold,
            stdThreshold: options.lightStdThreshold,
            maxThickness: maxBorderY
        )

        let (leftThickness, leftTone) = BorderStats.pickTone(dark: left, light: leftLight, minBorder: minBorderX)
        let (rightThickness, rightTone) = BorderStats.pickTone(dark: right, light: rightLight, minBorder: minBorderX)
        let (topThickness, topTone) = BorderStats.pickTone(dark: top, light: topLight, minBorder: minBorderY)
        let (bottomThickness, bottomTone) = BorderStats.pickTone(dark: bottom, light: bottomLight, minBorder: minBorderY)

        let hasAnyBorder = leftThickness > 0 || rightThickness > 0 || topThickness > 0 || bottomThickness > 0
        guard hasAnyBorder else { return nil }

        let safetyX = max(Int((Double(w) * options.safetyBorderFraction).rounded(.up)), options.safetyBorderPixels)
        let safetyY = max(Int((Double(h) * options.safetyBorderFraction).rounded(.up)), options.safetyBorderPixels)

        let x1 = max(0, leftThickness - safetyX)
        let x2 = min(w, w - rightThickness + safetyX)
        let y1 = max(0, topThickness - safetyY)
        let y2 = min(h, h - bottomThickness + safetyY)

        if x2 <= x1 || y2 <= y1 { return nil }

        let areaFraction = Double((x2 - x1) * (y2 - y1)) / Double(w * h)
        guard areaFraction >= options.minCropAreaFraction else { return nil }

        let probeCols = max(Int((Double(w) * options.probeFraction).rounded(.up)), 1)
        let probeRows = max(Int((Double(h) * options.probeFraction).rounded(.up)), 1)

        let leftConf = BorderStats.sideConfidenceFromStart(
            means: stats.colMean,
            stds: stats.colStd,
            thickness: leftThickness,
            tone: leftTone,
            darkStdThreshold: options.darkStdThreshold,
            lightStdThreshold: options.lightStdThreshold,
            probeCount: probeCols,
            deltaMin: options.deltaMin,
            deltaRange: options.deltaRange,
            thicknessFraction: Double(leftThickness) / Double(w),
            minBorderFraction: options.minBorderFraction
        )
        let rightConf = BorderStats.sideConfidenceFromEnd(
            means: stats.colMean,
            stds: stats.colStd,
            thickness: rightThickness,
            tone: rightTone,
            darkStdThreshold: options.darkStdThreshold,
            lightStdThreshold: options.lightStdThreshold,
            probeCount: probeCols,
            deltaMin: options.deltaMin,
            deltaRange: options.deltaRange,
            thicknessFraction: Double(rightThickness) / Double(w),
            minBorderFraction: options.minBorderFraction
        )
        let topConf = BorderStats.sideConfidenceFromStart(
            means: stats.rowMean,
            stds: stats.rowStd,
            thickness: topThickness,
            tone: topTone,
            darkStdThreshold: options.darkStdThreshold,
            lightStdThreshold: options.lightStdThreshold,
            probeCount: probeRows,
            deltaMin: options.deltaMin,
            deltaRange: options.deltaRange,
            thicknessFraction: Double(topThickness) / Double(h),
            minBorderFraction: options.minBorderFraction
        )
        let bottomConf = BorderStats.sideConfidenceFromEnd(
            means: stats.rowMean,
            stds: stats.rowStd,
            thickness: bottomThickness,
            tone: bottomTone,
            darkStdThreshold: options.darkStdThreshold,
            lightStdThreshold: options.lightStdThreshold,
            probeCount: probeRows,
            deltaMin: options.deltaMin,
            deltaRange: options.deltaRange,
            thicknessFraction: Double(bottomThickness) / Double(h),
            minBorderFraction: options.minBorderFraction
        )

        let confidences = [leftConf, rightConf, topConf, bottomConf].filter { $0 > 0 }
        let overallConfidence =
            confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        if overallConfidence <= 0 { return nil }

        let bbox = BorderStats.toNormalizedBBox(
            x1: x1,
            y1: y1,
            x2: x2,
            y2: y2,
            width: w,
            height: h
        )

        let metrics = VisionBorderCleanupMetrics(
            analysisWidth: w,
            analysisHeight: h,
            left: VisionBorderCleanupSideMetrics(thicknessPixels: leftThickness, tone: leftTone, confidence: leftConf),
            right: VisionBorderCleanupSideMetrics(
                thicknessPixels: rightThickness,
                tone: rightTone,
                confidence: rightConf
            ),
            top: VisionBorderCleanupSideMetrics(thicknessPixels: topThickness, tone: topTone, confidence: topConf),
            bottom: VisionBorderCleanupSideMetrics(
                thicknessPixels: bottomThickness,
                tone: bottomTone,
                confidence: bottomConf
            ),
            cropAreaFraction: areaFraction
        )

        return VisionBorderCleanupProposal(bbox: bbox, confidence: overallConfidence, metrics: metrics)
    }
}

private struct BorderStats: Sendable {
    var colMean: [Double]
    var colStd: [Double]
    var rowMean: [Double]
    var rowStd: [Double]

    static func compute(rgba: RGBA8Image) -> BorderStats {
        let w = rgba.width
        let h = rgba.height

        var colSum = [Int64](repeating: 0, count: w)
        var colSumSq = [Int64](repeating: 0, count: w)
        var rowSum = [Int64](repeating: 0, count: h)
        var rowSumSq = [Int64](repeating: 0, count: h)

        rgba.data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<h {
                for x in 0..<w {
                    let idx = (y * w + x) * 4
                    let r = base[idx]
                    let g = base[idx + 1]
                    let b = base[idx + 2]
                    let luma = luma8(r: r, g: g, b: b)
                    let v = Int64(luma)
                    colSum[x] += v
                    colSumSq[x] += v * v
                    rowSum[y] += v
                    rowSumSq[y] += v * v
                }
            }
        }

        var colMean = [Double](repeating: 0, count: w)
        var colStd = [Double](repeating: 0, count: w)
        var rowMean = [Double](repeating: 0, count: h)
        var rowStd = [Double](repeating: 0, count: h)

        let invH = 1.0 / Double(max(h, 1))
        for x in 0..<w {
            let mean = Double(colSum[x]) * invH
            let meanSq = Double(colSumSq[x]) * invH
            let variance = max(0, meanSq - mean * mean)
            colMean[x] = mean
            colStd[x] = sqrt(variance)
        }

        let invW = 1.0 / Double(max(w, 1))
        for y in 0..<h {
            let mean = Double(rowSum[y]) * invW
            let meanSq = Double(rowSumSq[y]) * invW
            let variance = max(0, meanSq - mean * mean)
            rowMean[y] = mean
            rowStd[y] = sqrt(variance)
        }

        return BorderStats(colMean: colMean, colStd: colStd, rowMean: rowMean, rowStd: rowStd)
    }

    static func detectThicknessFromStart(
        means: [Double],
        stds: [Double],
        tone: VisionBorderTone,
        meanThreshold: Double,
        stdThreshold: Double,
        maxThickness: Int
    ) -> Int {
        let limit = min(maxThickness, means.count)
        var t = 0
        while t < limit {
            let mean = means[t]
            let std = stds[t]
            let isBorder =
                switch tone {
                case .dark:
                    mean <= meanThreshold && std <= stdThreshold
                case .light:
                    mean >= meanThreshold && std <= stdThreshold
                }
            if !isBorder { break }
            t += 1
        }
        return t
    }

    static func detectThicknessFromEnd(
        means: [Double],
        stds: [Double],
        tone: VisionBorderTone,
        meanThreshold: Double,
        stdThreshold: Double,
        maxThickness: Int
    ) -> Int {
        let count = means.count
        let limit = min(maxThickness, count)
        var t = 0
        while t < limit {
            let idx = count - 1 - t
            let mean = means[idx]
            let std = stds[idx]
            let isBorder =
                switch tone {
                case .dark:
                    mean <= meanThreshold && std <= stdThreshold
                case .light:
                    mean >= meanThreshold && std <= stdThreshold
                }
            if !isBorder { break }
            t += 1
        }
        return t
    }

    static func pickTone(dark: Int, light: Int, minBorder: Int) -> (thickness: Int, tone: VisionBorderTone?) {
        let (t, tone): (Int, VisionBorderTone?) =
            if dark >= light {
                (dark, dark > 0 ? .dark : nil)
            } else {
                (light, light > 0 ? .light : nil)
            }
        if t < minBorder { return (0, nil) }
        return (t, tone)
    }

    static func sideConfidenceFromStart(
        means: [Double],
        stds: [Double],
        thickness: Int,
        tone: VisionBorderTone?,
        darkStdThreshold: Double,
        lightStdThreshold: Double,
        probeCount: Int,
        deltaMin: Double,
        deltaRange: Double,
        thicknessFraction: Double,
        minBorderFraction: Double
    ) -> Double {
        guard let tone, thickness > 0, thickness < means.count else { return 0 }
        let t = min(thickness, means.count)
        let probeStart = t
        let probeEnd = min(means.count, probeStart + max(probeCount, 1))
        guard probeEnd > probeStart else { return 0 }

        let borderMean = means[0..<t].reduce(0, +) / Double(t)
        let borderStd = stds[0..<t].reduce(0, +) / Double(t)
        let interiorMean = means[probeStart..<probeEnd].reduce(0, +) / Double(probeEnd - probeStart)

        return sideConfidence(
            borderMean: borderMean,
            borderStd: borderStd,
            interiorMean: interiorMean,
            tone: tone,
            darkStdThreshold: darkStdThreshold,
            lightStdThreshold: lightStdThreshold,
            deltaMin: deltaMin,
            deltaRange: deltaRange,
            thicknessFraction: thicknessFraction,
            minBorderFraction: minBorderFraction
        )
    }

    static func sideConfidenceFromEnd(
        means: [Double],
        stds: [Double],
        thickness: Int,
        tone: VisionBorderTone?,
        darkStdThreshold: Double,
        lightStdThreshold: Double,
        probeCount: Int,
        deltaMin: Double,
        deltaRange: Double,
        thicknessFraction: Double,
        minBorderFraction: Double
    ) -> Double {
        guard let tone, thickness > 0, thickness < means.count else { return 0 }
        let count = means.count
        let t = min(thickness, count)
        let borderStart = max(0, count - t)
        let probeEnd = borderStart
        let probeStart = max(0, probeEnd - max(probeCount, 1))
        guard probeEnd > probeStart else { return 0 }

        let borderMean = means[borderStart..<count].reduce(0, +) / Double(count - borderStart)
        let borderStd = stds[borderStart..<count].reduce(0, +) / Double(count - borderStart)
        let interiorMean = means[probeStart..<probeEnd].reduce(0, +) / Double(probeEnd - probeStart)

        return sideConfidence(
            borderMean: borderMean,
            borderStd: borderStd,
            interiorMean: interiorMean,
            tone: tone,
            darkStdThreshold: darkStdThreshold,
            lightStdThreshold: lightStdThreshold,
            deltaMin: deltaMin,
            deltaRange: deltaRange,
            thicknessFraction: thicknessFraction,
            minBorderFraction: minBorderFraction
        )
    }

    private static func sideConfidence(
        borderMean: Double,
        borderStd: Double,
        interiorMean: Double,
        tone: VisionBorderTone,
        darkStdThreshold: Double,
        lightStdThreshold: Double,
        deltaMin: Double,
        deltaRange: Double,
        thicknessFraction: Double,
        minBorderFraction: Double
    ) -> Double {
        let delta = abs(borderMean - interiorMean)
        let deltaScore = clamp01((delta - deltaMin) / max(deltaRange, 1e-6))

        let stdThreshold = tone == .dark ? darkStdThreshold : lightStdThreshold
        let uniformScore = clamp01((stdThreshold - borderStd) / max(stdThreshold, 1e-6))

        let thicknessScore = clamp01((thicknessFraction - minBorderFraction) / 0.12)

        return deltaScore * uniformScore * thicknessScore
    }

    static func toNormalizedBBox(
        x1: Int,
        y1: Int,
        x2: Int,
        y2: Int,
        width: Int,
        height: Int
    ) -> OCRNormalizedBBox {
        let w = Double(max(width, 1))
        let h = Double(max(height, 1))

        let nx1 = clampInt(Int(floor(Double(x1) / w * 1000.0)), min: 0, max: 1000)
        let nx2 = clampInt(Int(ceil(Double(x2) / w * 1000.0)), min: 0, max: 1000)
        let ny1 = clampInt(Int(floor(Double(y1) / h * 1000.0)), min: 0, max: 1000)
        let ny2 = clampInt(Int(ceil(Double(y2) / h * 1000.0)), min: 0, max: 1000)

        let fixedX1 = min(nx1, 999)
        let fixedY1 = min(ny1, 999)
        let fixedX2 = max(nx2, fixedX1 + 1)
        let fixedY2 = max(ny2, fixedY1 + 1)
        return OCRNormalizedBBox(x1: fixedX1, y1: fixedY1, x2: fixedX2, y2: fixedY2)
    }
}

@inline(__always)
private func luma8(r: UInt8, g: UInt8, b: UInt8) -> Int {
    // Approximate sRGB luma: 0.299 R + 0.587 G + 0.114 B
    (77 * Int(r) + 150 * Int(g) + 29 * Int(b) + 128) >> 8
}

@inline(__always)
private func clamp01(_ value: Double) -> Double {
    if value <= 0 { return 0 }
    if value >= 1 { return 1 }
    return value
}

@inline(__always)
private func clampInt(_ value: Int, min: Int, max: Int) -> Int {
    Swift.min(Swift.max(value, min), max)
}
