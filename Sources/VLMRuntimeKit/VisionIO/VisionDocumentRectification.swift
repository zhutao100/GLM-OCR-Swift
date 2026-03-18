import CoreGraphics
import CoreImage
import Foundation

public struct VisionQuad: Sendable, Codable, Equatable {
    public var topLeft: OCRNormalizedPoint
    public var topRight: OCRNormalizedPoint
    public var bottomRight: OCRNormalizedPoint
    public var bottomLeft: OCRNormalizedPoint

    public init(
        topLeft: OCRNormalizedPoint,
        topRight: OCRNormalizedPoint,
        bottomRight: OCRNormalizedPoint,
        bottomLeft: OCRNormalizedPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }
}

public struct VisionDocumentRectificationOptions: Sendable, Codable, Equatable {
    public var maxAnalysisDimension: Int
    public var minAreaFraction: Double
    public var maxAreaFraction: Double

    public init(maxAnalysisDimension: Int = 768, minAreaFraction: Double = 0.45, maxAreaFraction: Double = 0.98) {
        self.maxAnalysisDimension = maxAnalysisDimension
        self.minAreaFraction = minAreaFraction
        self.maxAreaFraction = maxAreaFraction
    }
}

public struct VisionDocumentRectificationProposal: Sendable, Codable, Equatable {
    public var quad: VisionQuad
    /// Area of the detected quad divided by the full image area (after any analysis scaling is accounted for).
    public var areaFraction: Double
    /// Heuristic confidence score in `[0, 1]`.
    public var confidence: Double

    public init(quad: VisionQuad, areaFraction: Double, confidence: Double) {
        self.quad = quad
        self.areaFraction = areaFraction
        self.confidence = confidence
    }
}

public enum VisionDocumentRectificationError: Error, Sendable, Equatable {
    case missingRectangleDetector
    case missingPerspectiveCorrectionFilter
    case cannotRectify
}

extension VisionIO {
    /// Propose a document quad for perspective rectification using Core Image's rectangle detector.
    ///
    /// This is intended as an experiment primitive. Callers should gate application by inspecting
    /// `areaFraction` and `confidence`.
    public static func proposeDocumentRectification(
        for image: CIImage,
        options: VisionDocumentRectificationOptions = .init()
    ) throws -> VisionDocumentRectificationProposal? {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let srcW = max(Int(extent.width.rounded(.down)), 1)
        let srcH = max(Int(extent.height.rounded(.down)), 1)

        let maxDim = max(srcW, srcH)
        let targetMax = max(options.maxAnalysisDimension, 1)
        let scale = min(CGFloat(1.0), CGFloat(targetMax) / CGFloat(maxDim))

        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard
            let detector = CIDetector(
                ofType: CIDetectorTypeRectangle,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
        else {
            throw VisionDocumentRectificationError.missingRectangleDetector
        }

        let rectangles = detector.features(in: scaled).compactMap { $0 as? CIRectangleFeature }
        guard !rectangles.isEmpty else { return nil }

        let scaledW = Double(srcW) * Double(scale)
        let scaledH = Double(srcH) * Double(scale)
        let imageArea = max(scaledW * scaledH, 1.0)

        var best: (feature: CIRectangleFeature, area: Double) = (rectangles[0], 0)
        for feature in rectangles {
            let area = polygonArea(
                feature.topLeft,
                feature.topRight,
                feature.bottomRight,
                feature.bottomLeft
            )
            if area > best.area {
                best = (feature, area)
            }
        }

        let areaFraction = max(0, min(1, best.area / imageArea))
        guard areaFraction >= options.minAreaFraction, areaFraction <= options.maxAreaFraction else { return nil }

        let quad = VisionQuad(
            topLeft: toNormalizedPoint(best.feature.topLeft, extent: extent, scale: scale),
            topRight: toNormalizedPoint(best.feature.topRight, extent: extent, scale: scale),
            bottomRight: toNormalizedPoint(best.feature.bottomRight, extent: extent, scale: scale),
            bottomLeft: toNormalizedPoint(best.feature.bottomLeft, extent: extent, scale: scale)
        )

        // Start with a simple signal: use area coverage as a proxy for detection confidence.
        let confidence = areaFraction
        return VisionDocumentRectificationProposal(quad: quad, areaFraction: areaFraction, confidence: confidence)
    }

    /// Apply perspective rectification to `image` using the provided quad.
    public static func applyDocumentRectification(
        _ image: CIImage,
        proposal: VisionDocumentRectificationProposal
    ) throws -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw VisionDocumentRectificationError.missingPerspectiveCorrectionFilter
        }

        let quad = proposal.quad
        let tl = toCIPoint(quad.topLeft, extent: extent)
        let tr = toCIPoint(quad.topRight, extent: extent)
        let br = toCIPoint(quad.bottomRight, extent: extent)
        let bl = toCIPoint(quad.bottomLeft, extent: extent)

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")

        guard let output = filter.outputImage else { throw VisionDocumentRectificationError.cannotRectify }

        let outExtent = output.extent.integral
        let translated = output.transformed(by: CGAffineTransform(translationX: -outExtent.minX, y: -outExtent.minY))
        return translated.cropped(to: CGRect(origin: .zero, size: outExtent.size))
    }
}

@inline(__always)
private func polygonArea(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> Double {
    // Shoelace formula for a quad (points are expected in order around the polygon).
    let pts = [p0, p1, p2, p3]
    var sum = 0.0
    for i in 0..<4 {
        let a = pts[i]
        let b = pts[(i + 1) % 4]
        sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
    }
    return abs(sum) * 0.5
}

@inline(__always)
private func toNormalizedPoint(_ p: CGPoint, extent: CGRect, scale: CGFloat) -> OCRNormalizedPoint {
    let invScale = 1.0 / max(scale, 1e-6)
    let x = (p.x * invScale)  // normalized image origin is (0, 0)
    let y = (p.y * invScale)

    let width = max(extent.width, 1.0)
    let height = max(extent.height, 1.0)

    let xNorm = Int((x / width * 1000.0).rounded())
    let yFromTop = (height - y)
    let yNorm = Int((yFromTop / height * 1000.0).rounded())

    return OCRNormalizedPoint(
        x: clampInt(xNorm, min: 0, max: 1000),
        y: clampInt(yNorm, min: 0, max: 1000)
    )
}

@inline(__always)
private func toCIPoint(_ p: OCRNormalizedPoint, extent: CGRect) -> CGPoint {
    let width = max(extent.width, 1.0)
    let height = max(extent.height, 1.0)

    let px = CGFloat(p.x) * width / 1000.0
    let pyFromTop = CGFloat(p.y) * height / 1000.0
    let ciX = extent.minX + px
    let ciY = extent.maxY - pyFromTop
    return CGPoint(x: ciX, y: ciY)
}

@inline(__always)
private func clampInt(_ value: Int, min: Int, max: Int) -> Int {
    Swift.min(Swift.max(value, min), max)
}
