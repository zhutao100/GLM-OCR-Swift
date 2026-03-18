import CoreImage
import Foundation

public enum VisionMedianDenoiseError: Error, Sendable, Equatable {
    case missingMedianFilter
    case cannotDenoise
}

extension VisionIO {
    /// Apply a small 3×3 median filter as a conservative denoise step.
    ///
    /// - Important: This is intended for opt-in experiments on noisy camera captures. Callers should gate use
    ///   carefully, especially for small crops where thin strokes can be softened.
    public static func applyMedianDenoise(_ image: CIImage) throws -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        guard let filter = CIFilter(name: "CIMedianFilter") else {
            throw VisionMedianDenoiseError.missingMedianFilter
        }
        filter.setValue(image, forKey: kCIInputImageKey)

        guard let output = filter.outputImage else { throw VisionMedianDenoiseError.cannotDenoise }
        return output.cropped(to: extent)
    }
}
