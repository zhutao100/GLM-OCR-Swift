import Foundation
import MLX

public struct GLMOCRNormalizationStats: Sendable, Equatable {
    public var mean: (Float, Float, Float)
    public var std: (Float, Float, Float)

    public init(mean: (Float, Float, Float), std: (Float, Float, Float)) {
        self.mean = mean
        self.std = std
    }

    public static func == (lhs: GLMOCRNormalizationStats, rhs: GLMOCRNormalizationStats) -> Bool {
        lhs.mean.0 == rhs.mean.0
            && lhs.mean.1 == rhs.mean.1
            && lhs.mean.2 == rhs.mean.2
            && lhs.std.0 == rhs.std.0
            && lhs.std.1 == rhs.std.1
            && lhs.std.2 == rhs.std.2
    }
}

public enum GLMOCRPreprocessorConfigLoader {
    public static func loadNormalizationStats(from modelFolder: URL) throws -> GLMOCRNormalizationStats? {
        let url = modelFolder.appendingPathComponent("preprocessor_config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(PreprocessorConfig.self, from: data)
        guard let mean = config.imageMean, let std = config.imageStd, mean.count == 3, std.count == 3 else {
            return nil
        }

        return GLMOCRNormalizationStats(
            mean: (mean[0], mean[1], mean[2]),
            std: (std[0], std[1], std[2])
        )
    }

    private struct PreprocessorConfig: Decodable, Sendable {
        var imageMean: [Float]?
        var imageStd: [Float]?

        private enum CodingKeys: String, CodingKey {
            case imageMean = "image_mean"
            case imageStd = "image_std"
        }
    }
}

enum GLMOCRRuntimeImageOptionsResolver {
    static func resolve(
        env: [String: String],
        normalizationStats: GLMOCRNormalizationStats?,
        visionInputDType: DType,
        preferredResizeBackend: GLMOCRResizeBackend? = nil,
        defaultOptions: GLMOCRImageProcessingOptions = .init()
    ) -> GLMOCRImageProcessingOptions {
        var options = defaultOptions

        if let backend = resizeBackend(from: env["GLMOCR_PREPROCESS_BACKEND"]) {
            options.resizeBackend = backend
        } else if let preferredResizeBackend {
            options.resizeBackend = preferredResizeBackend
        }

        if let quality = jpegQuality(from: env["GLMOCR_POST_RESIZE_JPEG_QUALITY"]) {
            options.postResizeJPEGRoundTripQuality = quality
        }

        if let normalizationStats {
            options.mean = normalizationStats.mean
            options.std = normalizationStats.std
        }

        let alignDTypeToVisionWeights = parseBool(env["GLMOCR_ALIGN_VISION_DTYPE"]) ?? true
        options.alignDTypeToVisionWeights = alignDTypeToVisionWeights

        if let explicitDType = parseDType(env["GLMOCR_VISION_INPUT_DTYPE"]) {
            options.alignDTypeToVisionWeights = false
            options.dtype = explicitDType
        } else if alignDTypeToVisionWeights {
            options.dtype = visionInputDType
        }

        return options
    }

    private static func resizeBackend(from raw: String?) -> GLMOCRResizeBackend? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "coreimage", "core_image", "coreimagebicubic":
            .coreImageBicubic
        case "deterministic", "deterministic_bicubic_cpu", "deterministicbicubiccpu":
            .deterministicBicubicCPU
        default:
            nil
        }
    }

    private static func jpegQuality(from raw: String?) -> Double? {
        guard let raw, let quality = Double(raw) else { return nil }
        return quality
    }

    private static func parseBool(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            true
        case "0", "false", "no", "off":
            false
        default:
            nil
        }
    }

    private static func parseDType(_ raw: String?) -> DType? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "float16", "fp16":
            .float16
        case "float32", "fp32":
            .float32
        case "bfloat16", "bf16":
            .bfloat16
        default:
            nil
        }
    }
}
