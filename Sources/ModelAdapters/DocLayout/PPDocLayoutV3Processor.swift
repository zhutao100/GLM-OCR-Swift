import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MLX
import VLMRuntimeKit

public struct PPDocLayoutV3ProcessedImage: @unchecked Sendable {
    public var pixelValues: MLXArray
    public var width: Int
    public var height: Int

    public init(pixelValues: MLXArray, width: Int, height: Int) {
        self.pixelValues = pixelValues
        self.width = width
        self.height = height
    }
}

/// PP-DocLayout-V3 image preprocessing (resize + rescale + normalize).
public struct PPDocLayoutV3Processor: Sendable {
    public var dtype: DType
    public var fallbackMeanStd: (mean: (Float, Float, Float), std: (Float, Float, Float))

    public init(
        dtype: DType = .bfloat16,
        fallbackMeanStd: (mean: (Float, Float, Float), std: (Float, Float, Float)) = ((0.5, 0.5, 0.5), (0.5, 0.5, 0.5))
    ) {
        self.dtype = dtype
        self.fallbackMeanStd = fallbackMeanStd
    }

    public func process(_ image: CIImage, preprocessorConfig: PPDocLayoutV3PreprocessorConfig?) throws -> PPDocLayoutV3ProcessedImage {
        let originalWidth = max(Int(image.extent.width.rounded(.down)), 1)
        let originalHeight = max(Int(image.extent.height.rounded(.down)), 1)

        let target: (width: Int, height: Int)? = preprocessorConfig?.targetSize(originalWidth: originalWidth, originalHeight: originalHeight)
        let resized: CIImage = if let target { resizeDirectly(image, width: target.width, height: target.height) } else { image }

        let w = max(Int(resized.extent.width.rounded(.down)), 1)
        let h = max(Int(resized.extent.height.rounded(.down)), 1)

        let baseTensor = try ImageTensorConverter.toTensor(resized, options: .init(dtype: .float32)).tensor
        var pixelValues = baseTensor

        if let config = preprocessorConfig {
            if config.doRescale == false {
                pixelValues *= 255.0
            } else if let factor = config.rescaleFactor {
                let scale = Float(factor * 255.0)
                if scale != 1 {
                    pixelValues *= scale
                }
            }

            if config.doNormalize != false {
                let meanStd = config.meanStd(fallbackMean: fallbackMeanStd.mean, fallbackStd: fallbackMeanStd.std)
                pixelValues = normalize(pixelValues, mean: meanStd.mean, std: meanStd.std)
            }
        } else {
            pixelValues = normalize(pixelValues, mean: fallbackMeanStd.mean, std: fallbackMeanStd.std)
        }

        pixelValues = pixelValues.asType(dtype)
        return PPDocLayoutV3ProcessedImage(pixelValues: pixelValues, width: w, height: h)
    }

    private func normalize(_ pixelValues: MLXArray, mean: (Float, Float, Float), std: (Float, Float, Float)) -> MLXArray {
        let meanArray = MLXArray([mean.0, mean.1, mean.2])
        let stdArray = MLXArray([std.0, std.1, std.2])
        return (pixelValues - meanArray) / stdArray
    }

    private func resizeDirectly(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let targetWidth = CGFloat(max(width, 1))
        let targetHeight = CGFloat(max(height, 1))
        let size = CGSize(width: targetWidth, height: targetHeight)

        let inputExtent = image.extent
        guard inputExtent.width > 0, inputExtent.height > 0 else { return image }

        let normalized = image.transformed(by: CGAffineTransform(translationX: -inputExtent.minX, y: -inputExtent.minY))

        let scaleX = targetWidth / normalized.extent.width
        let scaleY = targetHeight / normalized.extent.height

        let filter = CIFilter.bicubicScaleTransform()
        filter.inputImage = normalized
        filter.scale = Float(scaleY)
        filter.aspectRatio = Float(scaleX / scaleY)
        let scaledImage = filter.outputImage ?? normalized

        let scaledExtent = scaledImage.extent
        let scaledNormalized = scaledImage.transformed(by: CGAffineTransform(translationX: -scaledExtent.minX, y: -scaledExtent.minY))
        return scaledNormalized.cropped(to: CGRect(origin: .zero, size: size))
    }
}
