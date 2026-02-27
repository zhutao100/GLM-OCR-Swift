import Foundation
import MLX

public enum GenerationError: Error, Sendable {
    case notImplemented
}

/// Model-agnostic generation façade.
/// Adapters can wrap their model into this interface.
public protocol CausalLM: Sendable {
    func generate(prompt: String, pixelValues: MLXArray?, options: GenerateOptions) async throws -> (
        text: String, tokenIDs: [Int]?
    )
}

public struct GreedyGenerator: Sendable {
    public init() {}

    public func run(
        model: any CausalLM,
        prompt: String,
        pixelValues: MLXArray?,
        options: GenerateOptions
    ) async throws -> OCRResult {
        let (text, tokens) = try await model.generate(prompt: prompt, pixelValues: pixelValues, options: options)
        return OCRResult(text: text, rawTokens: tokens, diagnostics: .init())
    }
}
