import Foundation
import MLX

public enum WeightsError: Error, Sendable {
    case notImplemented
}

/// Placeholder for a future safetensors + dtype/quant loader.
///
/// In Phase 03, this should become:
/// - shard enumeration
/// - safetensors parsing
/// - key mapping + post-processing
/// - dtype casting policy
public struct WeightsLoader: Sendable {
    public init() {}

    public func loadAll(from _: URL, dtype _: DType?) throws -> [String: MLXArray] {
        throw WeightsError.notImplemented
    }
}
