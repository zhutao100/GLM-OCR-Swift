import Foundation
import VLMRuntimeKit

public enum GLMOCRModelError: Error, Sendable {
    case notImplemented
}

/// Placeholder for the actual GLM-OCR model.
/// Phase 03 replaces this with a real MLX Swift implementation and weight loading.
public struct GLMOCRModel: CausalLM, Sendable {
    public init() {}

    public static func load(from _: URL) async throws -> GLMOCRModel {
        // Phase 03: parse config.json, load weights, init modules.
        GLMOCRModel()
    }

    public func generate(prompt _: String, options _: GenerateOptions) async throws -> (text: String, tokenIDs: [Int]?) {
        // Phase 02+: tokenization + forward pass + decode loop.
        throw GLMOCRModelError.notImplemented
    }
}
