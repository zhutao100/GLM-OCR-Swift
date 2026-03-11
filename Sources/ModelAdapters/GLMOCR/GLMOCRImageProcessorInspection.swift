import CoreImage
import Foundation
import MLX
import VLMRuntimeKit

public struct GLMOCRImageTensorSummary: Sendable, Codable, Equatable {
    public var dtype: String
    public var minimum: Float
    public var maximum: Float
    public var mean: Float

    public init(dtype: String, minimum: Float, maximum: Float, mean: Float) {
        self.dtype = dtype
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
    }
}

public struct GLMOCRImageProcessingInspection: @unchecked Sendable {
    public let processed: GLMOCRProcessedImage
    public let originalWidth: Int
    public let originalHeight: Int
    public let targetWidth: Int
    public let targetHeight: Int
    public let resizedRGB: RGB8Image
    public let tensorSummary: GLMOCRImageTensorSummary

    public init(
        processed: GLMOCRProcessedImage,
        originalWidth: Int,
        originalHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        resizedRGB: RGB8Image,
        tensorSummary: GLMOCRImageTensorSummary
    ) {
        self.processed = processed
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.resizedRGB = resizedRGB
        self.tensorSummary = tensorSummary
    }
}

extension GLMOCRImageProcessor {
    public func inspect(_ image: CIImage, config: GLMOCRConfig) throws -> GLMOCRImageProcessingInspection {
        let prepared = try prepareImage(image, config: config, captureResizedRGB: true)
        let processed = makeProcessedImage(
            imageTensor: prepared.imageTensor,
            targetWidth: prepared.targetWidth,
            targetHeight: prepared.targetHeight,
            temporalPatchSize: prepared.temporalPatchSize,
            patchSize: prepared.patchSize,
            mergeSize: prepared.mergeSize
        )

        return GLMOCRImageProcessingInspection(
            processed: processed,
            originalWidth: prepared.originalWidth,
            originalHeight: prepared.originalHeight,
            targetWidth: prepared.targetWidth,
            targetHeight: prepared.targetHeight,
            resizedRGB: prepared.resizedRGB ?? RGB8Image(data: Data(), width: 0, height: 0),
            tensorSummary: tensorSummary(for: processed.pixelValues)
        )
    }

    struct PreparedImageTensor {
        var imageTensor: ImageTensor
        var originalWidth: Int
        var originalHeight: Int
        var targetWidth: Int
        var targetHeight: Int
        var patchSize: Int
        var temporalPatchSize: Int
        var mergeSize: Int
        var resizedRGB: RGB8Image?
    }

    func prepareImage(
        _ image: CIImage,
        config: GLMOCRConfig,
        captureResizedRGB: Bool
    ) throws -> PreparedImageTensor {
        let patchSize = config.visionConfig.patchSize ?? 14
        let temporalPatchSize = config.visionConfig.temporalPatchSize ?? 2
        let mergeSize = config.visionConfig.spatialMergeSize ?? 2

        let originalWidth = max(Int(image.extent.width.rounded(.down)), 1)
        let originalHeight = max(Int(image.extent.height.rounded(.down)), 1)

        let factor = max(patchSize * mergeSize * options.patchExpandFactor, 1)
        let (targetHeight, targetWidth) = smartResize(
            t: temporalPatchSize,
            height: originalHeight,
            width: originalWidth,
            tFactor: temporalPatchSize,
            heightFactor: factor,
            widthFactor: factor,
            minPixels: options.minPixels,
            maxPixels: options.maxPixels
        )

        let conversionOptions = ImageTensorConversionOptions(
            dtype: options.dtype,
            mean: options.mean,
            std: options.std
        )

        let imageTensor: ImageTensor
        let resizedRGB: RGB8Image?
        switch options.resizeBackend {
        case .coreImageBicubic:
            let resized = resizeDirectly(image, width: targetWidth, height: targetHeight)

            if let quality = options.postResizeJPEGRoundTripQuality {
                let rgba = try VisionRaster.renderRGBA8(resized)
                var rgb = try VisionResize.bicubicRGB(from: rgba, toWidth: targetWidth, toHeight: targetHeight)
                rgb = try VisionJPEG.roundTrip(rgb, quality: quality)
                imageTensor = try ImageTensorConverter.toTensor(rgb, options: conversionOptions)
                resizedRGB = rgb
            } else {
                imageTensor = try ImageTensorConverter.toTensor(resized, options: conversionOptions)
                if captureResizedRGB {
                    let rgba = try VisionRaster.renderRGBA8(resized)
                    resizedRGB = try VisionResize.bicubicRGB(from: rgba, toWidth: targetWidth, toHeight: targetHeight)
                } else {
                    resizedRGB = nil
                }
            }
        case .deterministicBicubicCPU:
            let rgba = try VisionRaster.renderRGBA8(image)
            var rgb = try VisionResize.bicubicRGB(from: rgba, toWidth: targetWidth, toHeight: targetHeight)
            if let quality = options.postResizeJPEGRoundTripQuality {
                rgb = try VisionJPEG.roundTrip(rgb, quality: quality)
            }
            imageTensor = try ImageTensorConverter.toTensor(rgb, options: conversionOptions)
            resizedRGB = captureResizedRGB ? rgb : nil
        }

        return PreparedImageTensor(
            imageTensor: imageTensor,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            patchSize: patchSize,
            temporalPatchSize: temporalPatchSize,
            mergeSize: mergeSize,
            resizedRGB: resizedRGB
        )
    }

    func makeProcessedImage(
        imageTensor: ImageTensor,
        targetWidth: Int,
        targetHeight: Int,
        temporalPatchSize: Int,
        patchSize: Int,
        mergeSize: Int
    ) -> GLMOCRProcessedImage {
        let hwc = imageTensor.tensor.squeezed(axis: 0)  // [H, W, C]
        let depth = temporalPatchSize
        let stacked = MLX.stacked(Array(repeating: hwc, count: depth), axis: 0)  // [D, H, W, C]
        let pixelValues = stacked.expandedDimensions(axis: 0)  // [1, D, H, W, C]

        let gridH = targetHeight / patchSize
        let gridW = targetWidth / patchSize
        let downH = gridH / mergeSize
        let downW = gridW / mergeSize
        let depthTokens = depth / temporalPatchSize
        let numImageTokens = depthTokens * downH * downW

        return GLMOCRProcessedImage(
            pixelValues: pixelValues,
            width: targetWidth,
            height: targetHeight,
            numImageTokens: numImageTokens
        )
    }

    private func tensorSummary(for pixelValues: MLXArray) -> GLMOCRImageTensorSummary {
        let values = pixelValues.asType(.float32).asArray(Float.self)
        guard let first = values.first else {
            return GLMOCRImageTensorSummary(
                dtype: String(describing: pixelValues.dtype),
                minimum: 0,
                maximum: 0,
                mean: 0
            )
        }

        var minimum = first
        var maximum = first
        var sum = Double(first)
        for value in values.dropFirst() {
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += Double(value)
        }

        return GLMOCRImageTensorSummary(
            dtype: String(describing: pixelValues.dtype),
            minimum: minimum,
            maximum: maximum,
            mean: Float(sum / Double(values.count))
        )
    }
}
