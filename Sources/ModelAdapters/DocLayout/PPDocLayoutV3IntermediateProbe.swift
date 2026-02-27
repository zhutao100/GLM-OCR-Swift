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
    private var pending: [String: MLXArray] = [:]
    private var pendingOrder: [String] = []
    private(set) var captures: [String: Capture] = [:]

    init(requested: [String: [[Int]]]) {
        self.requested = requested
    }

    func capture(_ name: String, tensor: MLXArray) {
        guard requested[name] != nil else { return }
        if pending[name] == nil {
            pendingOrder.append(name)
        }
        pending[name] = tensor
    }

    func finalize() {
        guard !pending.isEmpty else { return }

        var finished: [String: Capture] = [:]
        finished.reserveCapacity(pending.count)
        for name in pendingOrder {
            guard let tensor = pending[name] else { continue }
            guard let indices = requested[name] else { continue }

            tensor.eval()
            let dtypeString = String(describing: tensor.dtype)
            let capture = Capture(
                shape: tensor.shape,
                dtype: dtypeString,
                samples: indices.map { idx in
                    Sample(index: idx, value: scalar(from: tensor, index: idx))
                }
            )
            finished[name] = capture
        }
        pending.removeAll(keepingCapacity: true)
        pendingOrder.removeAll(keepingCapacity: true)
        captures = finished
    }

    private func scalar(from tensor: MLXArray, index: [Int]) -> Float {
        precondition(!index.isEmpty, "Probe scalar index must not be empty")
        precondition(index.count == tensor.ndim, "Index rank \(index.count) does not match tensor rank \(tensor.ndim)")

        for (axis, idx) in index.enumerated() {
            precondition(idx >= 0 && idx < tensor.dim(axis), "Index \(idx) out of bounds for axis \(axis)")
        }

        let value: MLXArray
        if index.count <= 4 {
            value =
                switch index.count {
                case 1:
                    tensor[index[0]]
                case 2:
                    tensor[index[0], index[1]]
                case 3:
                    tensor[index[0], index[1], index[2]]
                case 4:
                    tensor[index[0], index[1], index[2], index[3]]
                default:
                    fatalError("Unreachable")
                }
        } else {
            var sliced = tensor
            for idx in index {
                sliced = sliced[idx]
            }
            value = sliced
        }

        return value.asType(.float32).item(Float.self)
    }
}
