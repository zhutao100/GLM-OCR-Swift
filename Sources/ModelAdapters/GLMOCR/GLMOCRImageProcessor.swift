import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MLX
import VLMRuntimeKit

public struct GLMOCRImageProcessingOptions: Sendable {
    public var minPixels: Int
    public var maxPixels: Int
    public var patchExpandFactor: Int

    public var dtype: DType
    public var mean: (Float, Float, Float)
    public var std: (Float, Float, Float)

    public init(
        minPixels: Int = 12544,
        maxPixels: Int = 71_372_800,
        patchExpandFactor: Int = 1,
        dtype: DType = .bfloat16,
        mean: (Float, Float, Float) = (0.5, 0.5, 0.5),
        std: (Float, Float, Float) = (0.5, 0.5, 0.5)
    ) {
        self.minPixels = minPixels
        self.maxPixels = maxPixels
        self.patchExpandFactor = patchExpandFactor
        self.dtype = dtype
        self.mean = mean
        self.std = std
    }
}

public struct GLMOCRProcessedImage: @unchecked Sendable {
    public let pixelValues: MLXArray
    public let width: Int
    public let height: Int
    public let numImageTokens: Int

    public init(pixelValues: MLXArray, width: Int, height: Int, numImageTokens: Int) {
        self.pixelValues = pixelValues
        self.width = width
        self.height = height
        self.numImageTokens = numImageTokens
    }
}

/// GLM-OCR-specific vision preprocessing policy (resize + normalize).
///
/// `VLMRuntimeKit` provides the low-level decode + tensor conversion; this type encodes GLM-OCR’s
/// sizing/token budgeting rules (patch/merge factors and pixel budget).
public struct GLMOCRImageProcessor: Sendable {
    public var options: GLMOCRImageProcessingOptions

    public init(options: GLMOCRImageProcessingOptions = .init()) {
        self.options = options
    }

    public func process(_ image: CIImage, config: GLMOCRConfig) throws -> GLMOCRProcessedImage {
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

        let resized = resizeDirectly(image, width: targetWidth, height: targetHeight)

        let conversionOptions = ImageTensorConversionOptions(
            dtype: options.dtype,
            mean: options.mean,
            std: options.std
        )
        let imageTensor = try ImageTensorConverter.toTensor(resized, options: conversionOptions)

        let hwc = imageTensor.tensor.squeezed(axis: 0) // [H, W, C]
        let depth = temporalPatchSize
        let stacked = MLX.stacked(Array(repeating: hwc, count: depth), axis: 0) // [D, H, W, C]
        let pixelValues = stacked.expandedDimensions(axis: 0) // [1, D, H, W, C]

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

    // MARK: - Resizing helpers (ported from ../GLM-OCR/glmocr/utils/image_utils.py)

    private func smartResize(
        t: Int,
        height: Int,
        width: Int,
        tFactor: Int,
        heightFactor: Int,
        widthFactor: Int,
        minPixels: Int,
        maxPixels: Int
    ) -> (height: Int, width: Int) {
        precondition(tFactor > 0 && heightFactor > 0 && widthFactor > 0)
        precondition(t >= tFactor)

        let h = max(height, 1)
        let w = max(width, 1)
        let t = max(t, 1)

        func roundedToFactor(_ value: Int, factor: Int) -> Int {
            Int((Double(value) / Double(factor)).rounded()) * factor
        }

        var hBar = roundedToFactor(h, factor: heightFactor)
        var wBar = roundedToFactor(w, factor: widthFactor)
        let tBar = roundedToFactor(t, factor: tFactor)

        let minPixels = max(minPixels, 1)
        let maxPixels = max(maxPixels, minPixels)

        let current = Double(tBar) * Double(hBar) * Double(wBar)
        if current > Double(maxPixels) {
            let beta = sqrt((Double(t) * Double(h) * Double(w)) / Double(maxPixels))
            hBar = Int(floor(Double(h) / beta / Double(heightFactor))) * heightFactor
            wBar = Int(floor(Double(w) / beta / Double(widthFactor))) * widthFactor
        } else if current < Double(minPixels) {
            let beta = sqrt(Double(minPixels) / (Double(t) * Double(h) * Double(w)))
            hBar = Int(ceil(Double(h) * beta / Double(heightFactor))) * heightFactor
            wBar = Int(ceil(Double(w) * beta / Double(widthFactor))) * widthFactor
        }

        hBar = max(heightFactor, hBar)
        wBar = max(widthFactor, wBar)
        return (hBar, wBar)
    }

    private func resizeDirectly(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let targetWidth = CGFloat(max(width, 1))
        let targetHeight = CGFloat(max(height, 1))
        let size = CGSize(width: targetWidth, height: targetHeight)

        let scaleX = targetWidth / image.extent.width
        let scaleY = targetHeight / image.extent.height

        let filter = CIFilter.bicubicScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scaleY)
        filter.aspectRatio = Float(scaleX / scaleY)
        let scaledImage = filter.outputImage ?? image

        return scaledImage.cropped(to: CGRect(origin: .zero, size: size))
    }
}
