import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MLX
import VLMRuntimeKit

public enum GLMOCRResizeBackend: Sendable {
    case coreImageBicubic
    case deterministicBicubicCPU
}

public struct GLMOCRImageProcessingOptions: Sendable {
    public var minPixels: Int
    public var maxPixels: Int
    public var patchExpandFactor: Int

    public var dtype: DType
    public var mean: (Float, Float, Float)
    public var std: (Float, Float, Float)

    public var resizeBackend: GLMOCRResizeBackend
    public var postResizeJPEGRoundTripQuality: Double?  // nil = disabled
    public var alignDTypeToVisionWeights: Bool

    public init(
        minPixels: Int = 12544,
        maxPixels: Int = 71_372_800,
        patchExpandFactor: Int = 1,
        dtype: DType = .bfloat16,
        mean: (Float, Float, Float) = (0.5, 0.5, 0.5),
        std: (Float, Float, Float) = (0.5, 0.5, 0.5),
        resizeBackend: GLMOCRResizeBackend = .coreImageBicubic,
        postResizeJPEGRoundTripQuality: Double? = nil,
        alignDTypeToVisionWeights: Bool = false
    ) {
        self.minPixels = minPixels
        self.maxPixels = maxPixels
        self.patchExpandFactor = patchExpandFactor
        self.dtype = dtype
        self.mean = mean
        self.std = std
        self.resizeBackend = resizeBackend
        self.postResizeJPEGRoundTripQuality = postResizeJPEGRoundTripQuality
        self.alignDTypeToVisionWeights = alignDTypeToVisionWeights
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
        let prepared = try prepareImage(image, config: config, captureResizedRGB: false)
        return makeProcessedImage(
            imageTensor: prepared.imageTensor,
            targetWidth: prepared.targetWidth,
            targetHeight: prepared.targetHeight,
            temporalPatchSize: prepared.temporalPatchSize,
            patchSize: prepared.patchSize,
            mergeSize: prepared.mergeSize
        )
    }

    // MARK: - Resizing helpers (ported from ../GLM-OCR/glmocr/utils/image_utils.py)

    func smartResize(
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

    func resizeDirectly(_ image: CIImage, width: Int, height: Int) -> CIImage {
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
        let scaledNormalized = scaledImage.transformed(
            by: CGAffineTransform(translationX: -scaledExtent.minX, y: -scaledExtent.minY))
        return scaledNormalized.cropped(to: CGRect(origin: .zero, size: size))
    }
}
