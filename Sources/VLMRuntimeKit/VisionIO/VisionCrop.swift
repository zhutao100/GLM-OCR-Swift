import CoreGraphics
import CoreImage
import Foundation

public enum VisionCropError: Error, Sendable, Equatable {
    case invalidImageExtent(CGRect)
    case invalidCropRect(CGRect)
    case invalidNormalizedBBox(OCRNormalizedBBox)
    case cannotCreateMaskContext(width: Int, height: Int)
    case cannotCreateMaskImage
    case missingBlendWithMaskFilter
    case cannotBlendWithMask
}

extension VisionIO {
    /// Crop a region from an image using normalized coordinates in `[0, 1000]` with a top-left origin.
    ///
    /// If `polygon` is provided (>= 3 points), pixels outside the polygon are filled with `fillColor`.
    public static func cropRegion(
        image: CIImage,
        bbox: OCRNormalizedBBox,
        polygon: [OCRNormalizedPoint]?,
        fillColor: CIColor = .white
    ) throws -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else {
            throw VisionCropError.invalidImageExtent(extent)
        }

        guard Self.isValidNormalizedBBox(bbox) else {
            throw VisionCropError.invalidNormalizedBBox(bbox)
        }

        let width = extent.width
        let height = extent.height

        let x1px = (CGFloat(bbox.x1) * width / 1000.0).rounded(.down)
        let x2px = (CGFloat(bbox.x2) * width / 1000.0).rounded(.up)
        let y1px = (CGFloat(bbox.y1) * height / 1000.0).rounded(.down)
        let y2px = (CGFloat(bbox.y2) * height / 1000.0).rounded(.up)

        var cropRect = CGRect(
            x: extent.minX + x1px,
            y: extent.maxY - y2px,
            width: x2px - x1px,
            height: y2px - y1px
        )
        cropRect = cropRect.intersection(extent)
        guard cropRect.width > 0, cropRect.height > 0 else {
            throw VisionCropError.invalidCropRect(cropRect)
        }

        let cropped = image.cropped(to: cropRect)

        guard let polygon, polygon.count >= 3 else {
            return cropped
        }

        let mask = try makePolygonMask(
            imageExtent: extent,
            cropRect: cropRect,
            polygon: polygon
        )

        let background = CIImage(color: fillColor).cropped(to: cropRect)

        guard let filter = CIFilter(name: "CIBlendWithMask") else {
            throw VisionCropError.missingBlendWithMaskFilter
        }
        filter.setValue(cropped, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)

        guard let output = filter.outputImage else { throw VisionCropError.cannotBlendWithMask }

        return output.cropped(to: cropRect)
    }

    private static func isValidNormalizedBBox(_ bbox: OCRNormalizedBBox) -> Bool {
        let range = 0 ... 1000
        guard range.contains(bbox.x1), range.contains(bbox.y1), range.contains(bbox.x2), range.contains(bbox.y2) else {
            return false
        }
        guard bbox.x1 < bbox.x2, bbox.y1 < bbox.y2 else {
            return false
        }
        return true
    }

    private static func makePolygonMask(
        imageExtent: CGRect,
        cropRect: CGRect,
        polygon: [OCRNormalizedPoint]
    ) throws -> CIImage {
        let maskWidth = max(Int(cropRect.width.rounded(.up)), 1)
        let maskHeight = max(Int(cropRect.height.rounded(.up)), 1)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        guard let ctx = CGContext(
            data: nil,
            width: maskWidth,
            height: maskHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw VisionCropError.cannotCreateMaskContext(width: maskWidth, height: maskHeight)
        }

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: maskWidth, height: maskHeight))

        let width = imageExtent.width
        let height = imageExtent.height

        func toCILocalPoint(_ p: OCRNormalizedPoint) -> CGPoint {
            let px = CGFloat(p.x) * width / 1000.0
            let py = CGFloat(p.y) * height / 1000.0
            let ciX = imageExtent.minX + px
            let ciY = imageExtent.maxY - py
            return CGPoint(x: ciX - cropRect.minX, y: ciY - cropRect.minY)
        }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.beginPath()
        ctx.move(to: toCILocalPoint(polygon[0]))
        for p in polygon.dropFirst() {
            ctx.addLine(to: toCILocalPoint(p))
        }
        ctx.closePath()
        ctx.fillPath()

        guard let cgMask = ctx.makeImage() else {
            throw VisionCropError.cannotCreateMaskImage
        }

        let base = CIImage(cgImage: cgMask)
        return base.transformed(by: CGAffineTransform(translationX: cropRect.minX, y: cropRect.minY))
    }
}
