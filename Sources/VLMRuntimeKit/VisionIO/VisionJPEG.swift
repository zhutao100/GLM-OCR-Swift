import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VisionJPEGError: Error, Sendable, Equatable {
    case invalidInput(expected: Int, actual: Int)
    case encodeFailed
    case decodeFailed
}

public enum VisionJPEG {
    /// Encode to JPEG and decode back to RGB8 (useful to match SDK paths that round-trip through JPEG).
    ///
    /// - Returns: `RGB8Image` with the same `(width, height)`.
    public static func roundTrip(_ rgb: RGB8Image, quality: Double) throws -> RGB8Image {
        guard rgb.width > 0, rgb.height > 0 else {
            throw VisionJPEGError.invalidInput(expected: max(rgb.width, 0) * max(rgb.height, 0) * 3, actual: rgb.data.count)
        }

        let expectedBytes = rgb.width * rgb.height * 3
        guard rgb.data.count == expectedBytes else {
            throw VisionJPEGError.invalidInput(expected: expectedBytes, actual: rgb.data.count)
        }

        let rgba = try rgbToRGBA(rgb.data, width: rgb.width, height: rgb.height)
        let image = try makeRGBAImage(width: rgb.width, height: rgb.height, rgba: rgba)
        let jpegData = try encodeJPEGData(image, quality: quality)

        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
            let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw VisionJPEGError.decodeFailed
        }

        let decoded = try decodeRGBA(image: decodedImage)
        guard decoded.width == rgb.width, decoded.height == rgb.height else {
            throw VisionJPEGError.decodeFailed
        }

        let outRGB = try rgbaToRGB(decoded.data, width: rgb.width, height: rgb.height)
        return RGB8Image(data: outRGB, width: rgb.width, height: rgb.height)
    }

    private static func rgbToRGBA(_ rgb: Data, width: Int, height: Int) throws -> Data {
        let expectedBytes = width * height * 3
        guard rgb.count == expectedBytes else {
            throw VisionJPEGError.invalidInput(expected: expectedBytes, actual: rgb.count)
        }

        let pixelCount = width * height
        var rgba = Data(count: pixelCount * 4)
        try rgba.withUnsafeMutableBytes { dstPtr in
            try rgb.withUnsafeBytes { srcPtr in
                guard let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                    let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress
                else { throw VisionJPEGError.encodeFailed }

                var srcIndex = 0
                var dstIndex = 0
                for _ in 0..<pixelCount {
                    dstBase[dstIndex] = srcBase[srcIndex]
                    dstBase[dstIndex + 1] = srcBase[srcIndex + 1]
                    dstBase[dstIndex + 2] = srcBase[srcIndex + 2]
                    dstBase[dstIndex + 3] = 255
                    srcIndex += 3
                    dstIndex += 4
                }
            }
        }

        return rgba
    }

    private static func rgbaToRGB(_ rgba: Data, width: Int, height: Int) throws -> Data {
        let expectedBytes = width * height * 4
        guard rgba.count == expectedBytes else {
            throw VisionJPEGError.invalidInput(expected: expectedBytes, actual: rgba.count)
        }

        let pixelCount = width * height
        var rgb = Data(count: pixelCount * 3)
        try rgb.withUnsafeMutableBytes { dstPtr in
            try rgba.withUnsafeBytes { srcPtr in
                guard let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                    let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress
                else { throw VisionJPEGError.decodeFailed }

                var srcIndex = 0
                var dstIndex = 0
                for _ in 0..<pixelCount {
                    dstBase[dstIndex] = srcBase[srcIndex]
                    dstBase[dstIndex + 1] = srcBase[srcIndex + 1]
                    dstBase[dstIndex + 2] = srcBase[srcIndex + 2]
                    srcIndex += 4
                    dstIndex += 3
                }
            }
        }

        return rgb
    }

    private static func makeRGBAImage(width: Int, height: Int, rgba: Data) throws -> CGImage {
        guard width > 0, height > 0 else { throw VisionJPEGError.encodeFailed }

        let bytesPerRow = width * 4
        guard rgba.count == height * bytesPerRow else { throw VisionJPEGError.encodeFailed }

        guard let provider = CGDataProvider(data: rgba as CFData) else {
            throw VisionJPEGError.encodeFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        guard
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw VisionJPEGError.encodeFailed
        }

        return image
    }

    private static func encodeJPEGData(_ image: CGImage, quality: Double) throws -> Data {
        let clampedQuality = max(0.0, min(quality, 1.0))
        let data = NSMutableData()

        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            throw VisionJPEGError.encodeFailed
        }

        let options = [kCGImageDestinationLossyCompressionQuality: clampedQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)

        guard CGImageDestinationFinalize(destination) else {
            throw VisionJPEGError.encodeFailed
        }

        return data as Data
    }

    private static func decodeRGBA(image: CGImage) throws -> RGBA8Image {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var data = Data(count: height * bytesPerRow)
        try data.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else {
                throw VisionJPEGError.decodeFailed
            }

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

            guard
                let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                throw VisionJPEGError.decodeFailed
            }

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return RGBA8Image(data: data, width: width, height: height)
    }
}
