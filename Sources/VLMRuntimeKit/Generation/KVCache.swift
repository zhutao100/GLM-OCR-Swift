import Foundation
import MLX

public protocol KVCache: AnyObject {
    var offset: Int { get }
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray)
    func reset()
}

/// A simple append-only KV cache.
///
/// Stores keys/values in `[B, kvHeads, capacity, headDim]` tensors and grows as needed.
public final class KVCacheSimple: KVCache {
    private var keys: MLXArray?
    private var values: MLXArray?

    public private(set) var offset: Int = 0
    public var step: Int = 256

    public init() {}

    public func reset() {
        keys = nil
        values = nil
        offset = 0
    }

    public func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        let previous = offset
        let length = keys.dim(2)

        let needsReset: Bool =
            if let currentKeys = self.keys {
                (previous + length) > currentKeys.dim(2)
            } else {
                true
            }

        if needsReset {
            let batch = keys.dim(0)
            let kvHeads = keys.dim(1)
            let keyHeadDim = keys.dim(3)
            let valueHeadDim = values.dim(3)

            let needed = previous + length
            let currentCapacity = self.keys?.dim(2) ?? 0
            let grown = max(currentCapacity * 2, needed)
            let steps = (step + grown - 1) / step
            let capacity = max(steps * step, needed)

            let newKeys = MLXArray.zeros([batch, kvHeads, capacity, keyHeadDim], dtype: keys.dtype)
            let newValues = MLXArray.zeros([batch, kvHeads, capacity, valueHeadDim], dtype: values.dtype)

            if let oldKeys = self.keys, let oldValues = self.values, previous > 0 {
                newKeys[0..., 0..., 0..<previous, 0...] = oldKeys[0..., 0..., 0..<previous, 0...]
                newValues[0..., 0..., 0..<previous, 0...] = oldValues[0..., 0..., 0..<previous, 0...]
            }

            self.keys = newKeys
            self.values = newValues
        }

        guard let cachedKeys = self.keys, let cachedValues = self.values else {
            fatalError("KVCacheSimple internal allocation failed")
        }

        cachedKeys[0..., 0..., previous..<(previous + length), 0...] = keys
        cachedValues[0..., 0..., previous..<(previous + length), 0...] = values

        self.keys = cachedKeys
        self.values = cachedValues
        offset = previous + length

        return (cachedKeys[0..., 0..., 0..<offset, 0...], cachedValues[0..., 0..., 0..<offset, 0...])
    }
}
