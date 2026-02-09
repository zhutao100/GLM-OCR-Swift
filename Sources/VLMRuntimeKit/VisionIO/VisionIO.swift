import CoreGraphics
import CoreImage
#if canImport(PDFKit)
    import PDFKit
#endif
import Foundation
import MLX

public enum VisionIOError: Error, Sendable {
    case cannotDecodeImage(URL)
    case cannotRenderPDF(URL)
    case invalidPDFPageIndex(Int)
}

/// Minimal vision IO helpers.
/// The actual preprocessing policy (smart resize, tiling, etc.) belongs in the model adapter.
public enum VisionIO {
    public static func loadCIImage(from url: URL) throws -> CIImage {
        guard let ci = CIImage(contentsOf: url) else {
            throw VisionIOError.cannotDecodeImage(url)
        }
        return ci
    }

    /// Render a single PDF page into a CIImage.
    ///
    /// - Parameters:
    ///   - url: PDF file URL.
    ///   - page: 1-based page index.
    ///   - dpi: Rendering DPI (PDF points are 72 DPI).
    public static func loadCIImage(fromPDF url: URL, page: Int, dpi: CGFloat = 200) throws -> CIImage {
        guard page >= 1 else { throw VisionIOError.invalidPDFPageIndex(page) }

        #if canImport(PDFKit)
            guard let doc = PDFDocument(url: url), let pdfPage = doc.page(at: page - 1) else {
                throw VisionIOError.cannotRenderPDF(url)
            }

            let pageRect = pdfPage.bounds(for: .mediaBox)
            let scale = max(dpi / 72.0, 0.01)
            let pixelWidth = max(Int((pageRect.width * scale).rounded(.up)), 1)
            let pixelHeight = max(Int((pageRect.height * scale).rounded(.up)), 1)

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

            guard let ctx = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                throw VisionIOError.cannotRenderPDF(url)
            }

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

            // PDFKit draws in a coordinate system where Y+ is up; bitmap contexts are also Y+ up.
            // Scale from points (72 DPI) to desired pixel density, then draw the page.
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            pdfPage.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            guard let cg = ctx.makeImage() else { throw VisionIOError.cannotRenderPDF(url) }
            return CIImage(cgImage: cg)
        #else
            throw VisionIOError.cannotRenderPDF(url)
        #endif
    }
}

// MARK: - MLX conversion (starter stub)

public struct ImageTensor: @unchecked Sendable {
    public let tensor: MLXArray
    public let width: Int
    public let height: Int

    public init(tensor: MLXArray, width: Int, height: Int) {
        self.tensor = tensor
        self.width = width
        self.height = height
    }
}

public struct ImageTensorConversionOptions: Sendable {
    public var dtype: DType
    public var mean: (Float, Float, Float)?
    public var std: (Float, Float, Float)?

    public init(dtype: DType = .bfloat16, mean: (Float, Float, Float)? = nil, std: (Float, Float, Float)? = nil) {
        self.dtype = dtype
        self.mean = mean
        self.std = std
    }
}

public enum ImageTensorConverter {
    /// Convert a CIImage into a normalized `[1, H, W, C]` float tensor (channels last).
    ///
    /// - Note: This is a low-level primitive. Model adapters should own resize policy and
    ///   provide mean/std constants (or load them from the model snapshot).
    public static func toTensor(_ image: CIImage, options: ImageTensorConversionOptions = .init()) throws -> ImageTensor {
        let extent = image.extent.integral
        let w = max(Int(extent.width), 0)
        let h = max(Int(extent.height), 0)
        guard w > 0, h > 0 else {
            return ImageTensor(tensor: MLXArray(0), width: w, height: h)
        }

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

        let uint8Array = MLXArray(data, [h, w, 4], type: UInt8.self)
        var array = uint8Array.asType(.float32) / 255.0
        array = array[0..., 0..., ..<3] // drop alpha
        array = array.reshaped(1, h, w, 3)

        if let mean = options.mean, let std = options.std {
            let meanArray = MLXArray([mean.0, mean.1, mean.2])
            let stdArray = MLXArray([std.0, std.1, std.2])
            array = (array - meanArray) / stdArray
        }

        return ImageTensor(tensor: array.asType(options.dtype), width: w, height: h)
    }
}
