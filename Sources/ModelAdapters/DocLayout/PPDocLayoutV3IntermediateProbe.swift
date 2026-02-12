import MLX

final class PPDocLayoutV3IntermediateProbe: @unchecked Sendable {
    struct Sample: Sendable, Equatable {
        var index: [Int]
        var value: Float
    }

    struct Capture: Sendable, Equatable {
        var shape: [Int]
        var dtype: String
        var samples: [Sample]
    }

    private let requested: [String: [[Int]]]
    private(set) var captures: [String: Capture] = [:]

    init(requested: [String: [[Int]]]) {
        self.requested = requested
    }

    func capture(_ name: String, tensor: MLXArray) {
        guard let indices = requested[name] else { return }

        let dtypeString = String(describing: tensor.dtype)
        let capture = Capture(
            shape: tensor.shape,
            dtype: dtypeString,
            samples: indices.map { idx in
                Sample(index: idx, value: scalar(from: tensor, index: idx))
            }
        )
        captures[name] = capture
    }

    private func scalar(from tensor: MLXArray, index: [Int]) -> Float {
        precondition(!index.isEmpty, "Probe scalar index must not be empty")
        precondition(index.count == tensor.ndim, "Index rank \(index.count) does not match tensor rank \(tensor.ndim)")

        for (axis, idx) in index.enumerated() {
            precondition(idx >= 0 && idx < tensor.dim(axis), "Index \(idx) out of bounds for axis \(axis)")
        }

        let value: MLXArray = switch index.count {
        case 1:
            tensor[index[0]]
        case 2:
            tensor[index[0], index[1]]
        case 3:
            tensor[index[0], index[1], index[2]]
        case 4:
            tensor[index[0], index[1], index[2], index[3]]
        default:
            fatalError("Unsupported scalar rank: \(index.count)")
        }

        return value.asType(.float32).item(Float.self)
    }
}
