import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VisionWriteError: Error, Sendable, Equatable {
    case cannotCreateCGImage
    case cannotCreateCGDataProvider
    case cannotCreateDestination(URL)
    case cannotFinalizeDestination(URL)
}

extension VisionIO {
    /// Write a CIImage as a JPEG file.
    public static func writeJPEG(_ image: CIImage, to url: URL, quality: CGFloat = 0.95) throws {
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw VisionWriteError.cannotCreateCGImage
        }

        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            throw VisionWriteError.cannotCreateDestination(url)
        }

        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)

        guard CGImageDestinationFinalize(destination) else {
            throw VisionWriteError.cannotFinalizeDestination(url)
        }
    }

    /// Write an `RGB8Image` as a PNG file.
    public static func writePNG(_ image: RGB8Image, to url: URL) throws {
        guard image.width > 0, image.height > 0 else {
            throw VisionWriteError.cannotCreateCGImage
        }
        let expectedBytes = image.width * image.height * 3
        guard image.data.count == expectedBytes else {
            throw VisionWriteError.cannotCreateCGImage
        }

        var rgba = Data(count: image.width * image.height * 4)
        rgba.withUnsafeMutableBytes { dstPtr in
            image.data.withUnsafeBytes { srcPtr in
                guard let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                    let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress
                else {
                    return
                }

                var srcIndex = 0
                var dstIndex = 0
                for _ in 0..<(image.width * image.height) {
                    dstBase[dstIndex] = srcBase[srcIndex]
                    dstBase[dstIndex + 1] = srcBase[srcIndex + 1]
                    dstBase[dstIndex + 2] = srcBase[srcIndex + 2]
                    dstBase[dstIndex + 3] = 255
                    srcIndex += 3
                    dstIndex += 4
                }
            }
        }

        guard let provider = CGDataProvider(data: rgba as CFData) else {
            throw VisionWriteError.cannotCreateCGDataProvider
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        guard
            let cgImage = CGImage(
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw VisionWriteError.cannotCreateCGImage
        }

        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw VisionWriteError.cannotCreateDestination(url)
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw VisionWriteError.cannotFinalizeDestination(url)
        }
    }
}
