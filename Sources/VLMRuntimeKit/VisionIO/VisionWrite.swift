import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VisionWriteError: Error, Sendable, Equatable {
    case cannotCreateCGImage
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
}
