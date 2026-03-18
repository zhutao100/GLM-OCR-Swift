import CoreImage
import Foundation

public struct VisionNoiseReductionOptions: Sendable, Codable, Equatable {
    /// Noise level in `[0, 1]`. Higher values apply stronger smoothing.
    public var noiseLevel: Double
    /// Sharpness in `[0, 1]`. Higher values preserve more edges at the cost of leaving noise behind.
    public var sharpness: Double

    public init(noiseLevel: Double = 0.02, sharpness: Double = 0.40) {
        self.noiseLevel = noiseLevel
        self.sharpness = sharpness
    }
}

public enum VisionNoiseReductionDenoiseError: Error, Sendable, Equatable {
    case missingNoiseReductionFilter
    case cannotDenoise
}

extension VisionIO {
    /// Apply Core Image noise reduction as a stronger (and riskier) denoise experiment.
    public static func applyNoiseReductionDenoise(
        _ image: CIImage,
        options: VisionNoiseReductionOptions = .init()
    ) throws -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        guard let filter = CIFilter(name: "CINoiseReduction") else {
            throw VisionNoiseReductionDenoiseError.missingNoiseReductionFilter
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(options.noiseLevel, forKey: "inputNoiseLevel")
        filter.setValue(options.sharpness, forKey: "inputSharpness")

        guard let output = filter.outputImage else { throw VisionNoiseReductionDenoiseError.cannotDenoise }
        return output.cropped(to: extent)
    }
}
