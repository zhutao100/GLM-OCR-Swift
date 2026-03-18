import CoreImage
import Foundation

public struct VisionDeskewOptions: Sendable, Codable, Equatable {
    public var maxAnalysisDimension: Int
    public var maxAngleDegrees: Double
    public var stepDegrees: Double
    public var edgeMagnitudeThreshold: Int
    public var sampleStride: Int
    public var ignoreBorderFraction: Double
    public var minApplyAngleDegrees: Double
    public var minConfidence: Double

    public init(
        maxAnalysisDimension: Int = 1024,
        maxAngleDegrees: Double = 5.0,
        stepDegrees: Double = 0.5,
        edgeMagnitudeThreshold: Int = 55,
        sampleStride: Int = 2,
        ignoreBorderFraction: Double = 0.06,
        minApplyAngleDegrees: Double = 0.75,
        minConfidence: Double = 0.08
    ) {
        self.maxAnalysisDimension = maxAnalysisDimension
        self.maxAngleDegrees = maxAngleDegrees
        self.stepDegrees = stepDegrees
        self.edgeMagnitudeThreshold = edgeMagnitudeThreshold
        self.sampleStride = sampleStride
        self.ignoreBorderFraction = ignoreBorderFraction
        self.minApplyAngleDegrees = minApplyAngleDegrees
        self.minConfidence = minConfidence
    }
}

public struct VisionDeskewEstimate: Sendable, Codable, Equatable {
    public var angleDegrees: Double
    public var confidence: Double
    public var bestScore: Double
    public var secondBestScore: Double

    public init(angleDegrees: Double, confidence: Double, bestScore: Double, secondBestScore: Double) {
        self.angleDegrees = angleDegrees
        self.confidence = confidence
        self.bestScore = bestScore
        self.secondBestScore = secondBestScore
    }
}

public enum VisionDeskewError: Error, Sendable, Equatable {
    case missingStraightenFilter
    case cannotStraighten
}

extension VisionIO {
    /// Estimate a small skew angle (in degrees) for the given page image.
    ///
    /// This is a lightweight, deterministic heuristic intended for conservative, high-confidence deskew passes.
    public static func estimateDeskewAngle(
        for image: CIImage,
        options: VisionDeskewOptions = .init()
    ) throws -> VisionDeskewEstimate? {
        let analysis = try VisionRaster.renderRGBA8(
            image,
            maxDimension: options.maxAnalysisDimension,
            useSoftwareRenderer: true
        )
        return estimateDeskewAngle(for: analysis, options: options)
    }

    /// Apply deskew by rotating the image by `angleDegrees` (positive values rotate counterclockwise).
    public static func applyDeskew(
        _ image: CIImage,
        angleDegrees: Double,
        fillColor: CIColor = .white
    ) throws -> CIImage {
        guard let filter = CIFilter(name: "CIStraightenFilter") else {
            throw VisionDeskewError.missingStraightenFilter
        }

        let angleRadians = angleDegrees * .pi / 180.0
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(angleRadians, forKey: kCIInputAngleKey)

        guard let output = filter.outputImage else { throw VisionDeskewError.cannotStraighten }

        let outExtent = output.extent.integral
        let background = CIImage(color: fillColor).cropped(to: outExtent)
        let filled = output.composited(over: background).cropped(to: outExtent)

        let translated = filled.transformed(by: CGAffineTransform(translationX: -outExtent.minX, y: -outExtent.minY))
        return translated.cropped(to: CGRect(origin: .zero, size: outExtent.size))
    }

    static func estimateDeskewAngle(for rgba: RGBA8Image, options: VisionDeskewOptions) -> VisionDeskewEstimate? {
        let w = rgba.width
        let h = rgba.height
        guard w >= 3, h >= 3 else { return nil }

        let sampleStride = max(options.sampleStride, 1)
        let edgeThreshold = max(options.edgeMagnitudeThreshold, 0)
        let ignoreBorderFraction = max(0, min(0.45, options.ignoreBorderFraction))

        let maxAngle = abs(options.maxAngleDegrees)
        let step = max(options.stepDegrees, 0.05)
        guard maxAngle >= step else { return nil }

        let luma = computeLuma(rgba: rgba)

        let borderX = Int((Double(w) * ignoreBorderFraction).rounded(.toNearestOrAwayFromZero))
        let borderY = Int((Double(h) * ignoreBorderFraction).rounded(.toNearestOrAwayFromZero))
        let startX = max(1 + borderX, 1)
        let endX = max(min(w - 2 - borderX, w - 2), startX)
        let startY = max(1 + borderY, 1)
        let endY = max(min(h - 2 - borderY, h - 2), startY)

        let binCount = Int((2.0 * maxAngle / step).rounded(.toNearestOrAwayFromZero)) + 1
        guard binCount >= 3 else { return nil }

        var weightSums = [Double](repeating: 0, count: binCount)
        var weightedAngleSums = [Double](repeating: 0, count: binCount)
        var sampleCount = 0

        func idx(_ x: Int, _ y: Int) -> Int { y * w + x }

        for y in stride(from: startY, through: endY, by: sampleStride) {
            for x in stride(from: startX, through: endX, by: sampleStride) {
                let i00 = idx(x - 1, y - 1)
                let i10 = idx(x, y - 1)
                let i20 = idx(x + 1, y - 1)
                let i01 = idx(x - 1, y)
                let i21 = idx(x + 1, y)
                let i02 = idx(x - 1, y + 1)
                let i12 = idx(x, y + 1)
                let i22 = idx(x + 1, y + 1)

                let gx =
                    (-Int(luma[i00]) + Int(luma[i20]))
                    + (-2 * Int(luma[i01]) + 2 * Int(luma[i21]))
                    + (-Int(luma[i02]) + Int(luma[i22]))
                let gy =
                    (-Int(luma[i00]) - 2 * Int(luma[i10]) - Int(luma[i20]))
                    + (Int(luma[i02]) + 2 * Int(luma[i12]) + Int(luma[i22]))

                let magnitude = abs(gx) + abs(gy)
                if magnitude < edgeThreshold { continue }

                let angle = foldAngleToMinus90To90(atan2(-Double(gx), Double(gy)) * 180.0 / .pi)
                if abs(angle) > maxAngle { continue }

                let scaled = (angle + maxAngle) / step
                let bin = Int(scaled.rounded(.toNearestOrAwayFromZero))
                if bin < 0 || bin >= binCount { continue }

                let weight = Double(magnitude)
                weightSums[bin] += weight
                weightedAngleSums[bin] += weight * angle
                sampleCount += 1
            }
        }

        guard sampleCount >= 256 else { return nil }

        var bestScore = -Double.infinity
        var bestBin = -1
        var secondBestScore = -Double.infinity

        for (i, score) in weightSums.enumerated() {
            if score > bestScore {
                secondBestScore = bestScore
                bestScore = score
                bestBin = i
            } else if score > secondBestScore {
                secondBestScore = score
            }
        }

        guard bestBin >= 0, bestScore.isFinite, bestScore > 0 else { return nil }

        let angleDegrees =
            if weightedAngleSums[bestBin] != 0 {
                weightedAngleSums[bestBin] / bestScore
            } else {
                -maxAngle + Double(bestBin) * step
            }

        let zeroBin = max(0, min(binCount - 1, Int((maxAngle / step).rounded(.toNearestOrAwayFromZero))))
        let scoreAtZero = weightSums[zeroBin]
        let confidence = max(0, min(1, (bestScore - scoreAtZero) / bestScore))
        guard abs(angleDegrees) >= options.minApplyAngleDegrees else { return nil }
        guard confidence >= options.minConfidence else { return nil }

        return VisionDeskewEstimate(
            angleDegrees: angleDegrees,
            confidence: confidence,
            bestScore: bestScore,
            secondBestScore: secondBestScore
        )
    }
}

private func computeLuma(rgba: RGBA8Image) -> [UInt8] {
    let w = rgba.width
    let h = rgba.height
    var out = [UInt8](repeating: 0, count: w * h)
    rgba.data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        var idx = 0
        for i in 0..<(w * h) {
            let r = base[idx]
            let g = base[idx + 1]
            let b = base[idx + 2]
            out[i] = UInt8(clampInt(luma8(r: r, g: g, b: b), min: 0, max: 255))
            idx += 4
        }
    }
    return out
}

@inline(__always)
private func luma8(r: UInt8, g: UInt8, b: UInt8) -> Int {
    (77 * Int(r) + 150 * Int(g) + 29 * Int(b) + 128) >> 8
}

@inline(__always)
private func clampInt(_ value: Int, min: Int, max: Int) -> Int {
    Swift.min(Swift.max(value, min), max)
}

@inline(__always)
private func foldAngleToMinus90To90(_ angle: Double) -> Double {
    var v = angle.truncatingRemainder(dividingBy: 180)
    if v <= -90 { v += 180 }
    if v > 90 { v -= 180 }
    return v
}
