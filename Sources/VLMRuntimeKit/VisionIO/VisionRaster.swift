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
}
