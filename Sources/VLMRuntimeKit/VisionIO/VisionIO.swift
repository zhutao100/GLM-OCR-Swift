import CoreGraphics
import CoreImage
import Foundation
import MLX

public enum VisionIOError: Error, Sendable {
    case cannotDecodeImage(URL)
    case cannotRenderPDF(URL)
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
}

// MARK: - MLX conversion (starter stub)

public struct ImageTensor: Sendable, Equatable {
    public var tensor: MLXArray
    public var width: Int
    public var height: Int

    public init(tensor: MLXArray, width: Int, height: Int) {
        self.tensor = tensor
        self.width = width
        self.height = height
    }
}

public enum ImageTensorConverter {
    /// Convert a CIImage into a normalized (H, W, C) float tensor.
    ///
    /// Starter implementation is a stub: it returns an empty tensor.
    /// Phase 02 should implement:
    /// - CIContext render -> RGBA8 buffer
    /// - convert to Float32/Float16/BFloat16
    /// - normalize (mean/std) as required by the vision encoder
    public static func toTensor(_ image: CIImage) throws -> ImageTensor {
        let extent = image.extent.integral
        let w = max(Int(extent.width), 0)
        let h = max(Int(extent.height), 0)
        // Stub tensor to keep compilation green.
        return ImageTensor(tensor: MLXArray(0), width: w, height: h)
    }
}
