import Foundation
import VLMRuntimeKit

public enum GLMOCRDefaults {
    public static let modelID = "zai-org/GLM-OCR"
    public static let revision = "main"

    /// Conservative set of glob patterns for snapshot download.
    /// Tighten/expand once the exact GLM-OCR artifacts are confirmed.
    public static let downloadGlobs: [String] = [
        "*.safetensors",
        "*.json",
        "tokenizer.*",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "preprocessor_config.json",
    ]
}
