import CoreGraphics
import CoreImage
import Foundation

public enum VisionRasterError: Error, Sendable, Equatable {
    case invalidImageExtent(CGRect)
}

public struct RGBA8Image: Sendable, Equatable {
    public let data: Data
    public let width: Int
    public let height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

public struct RGB8Image: Sendable, Equatable {
    public let data: Data
    public let width: Int
    public let height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

public enum VisionRaster {
    /// Deterministically render a `CIImage` into an `RGBA8` byte buffer.
    ///
    /// - Returns: `RGBA8Image` where `data.count == width * height * 4`.
    public static func renderRGBA8(_ image: CIImage) throws -> RGBA8Image {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { throw VisionRasterError.invalidImageExtent(extent) }

        let w = Int(extent.width)
        let h = Int(extent.height)

        let format = CIFormat.RGBA8
        let componentsPerPixel = 4
        let bytesPerRow = w * componentsPerPixel

        var data = Data(count: w * h * componentsPerPixel)
        let context = CIContext()

        data.withUnsafeMutableBytes { ptr in
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            context.render(
                image,
                toBitmap: ptr.baseAddress!,
                rowBytes: bytesPerRow,
                bounds: extent,
                format: format,
                colorSpace: colorSpace
            )
            context.clearCaches()
        }

        return RGBA8Image(data: data, width: w, height: h)
    }

    /// Deterministically render a `CIImage` into an `RGBA8` byte buffer, optionally downsampling
    /// so that the output `max(width, height) <= maxDimension`.
    ///
    /// - Note: This is intended for lightweight analysis passes (border heuristics, skew probes, etc.).
    public static func renderRGBA8(
        _ image: CIImage,
        maxDimension: Int,
        useSoftwareRenderer: Bool = true
    ) throws -> RGBA8Image {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { throw VisionRasterError.invalidImageExtent(extent) }

        let srcW = max(Int(extent.width), 1)
        let srcH = max(Int(extent.height), 1)
        let targetMax = max(maxDimension, 1)

        let maxDim = max(srcW, srcH)
        let scale = min(CGFloat(1.0), CGFloat(targetMax) / CGFloat(maxDim))
        let targetW = max(Int((CGFloat(srcW) * scale).rounded(.toNearestOrAwayFromZero)), 1)
        let targetH = max(Int((CGFloat(srcH) * scale).rounded(.toNearestOrAwayFromZero)), 1)

        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let targetRect = CGRect(x: 0, y: 0, width: CGFloat(targetW), height: CGFloat(targetH))
        let cropped = scaled.cropped(to: targetRect)

        let format = CIFormat.RGBA8
        let componentsPerPixel = 4
        let bytesPerRow = targetW * componentsPerPixel

        var data = Data(count: targetW * targetH * componentsPerPixel)
        let options: [CIContextOption: Any]? =
            useSoftwareRenderer ? [.useSoftwareRenderer: true] : nil
        let context = CIContext(options: options)

        data.withUnsafeMutableBytes { ptr in
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            context.render(
                cropped,
                toBitmap: ptr.baseAddress!,
                rowBytes: bytesPerRow,
                bounds: targetRect,
                format: format,
                colorSpace: colorSpace
            )
            context.clearCaches()
        }

        return RGBA8Image(data: data, width: targetW, height: targetH)
    }
}
