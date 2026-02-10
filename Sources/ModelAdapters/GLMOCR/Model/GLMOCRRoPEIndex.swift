import Foundation
import MLX

enum GLMOCRRoPEIndexError: Error, Sendable {
    case expectedBatchFirst2DInputIds(shape: [Int])
    case missingImageGridTHW
    case multipleImagesNotSupported(requested: Int)
    case imageTokenCountMismatch(expected: Int, actual: Int)
    case videoNotImplemented
}

/// Port of Transformers `GlmOcrModel.get_rope_index` for the common single-image case.
enum GLMOCRRoPEIndex {
    struct Output: @unchecked Sendable {
        let positionIds: MLXArray // [3, B, S] int32
        let ropeDeltas: MLXArray // [B, 1] int32
    }

    static func compute(
        inputIds: MLXArray,
        imageGridTHW: (t: Int, h: Int, w: Int)?,
        spatialMergeSize: Int,
        imageTokenId: Int,
        videoStartTokenId: Int?,
        videoEndTokenId: Int?
    ) throws -> Output {
        guard inputIds.ndim == 2 else {
            throw GLMOCRRoPEIndexError.expectedBatchFirst2DInputIds(shape: inputIds.shape)
        }

        let batch = inputIds.dim(0)
        let seqLen = inputIds.dim(1)

        guard let imageGridTHW else {
            throw GLMOCRRoPEIndexError.missingImageGridTHW
        }

        var positionStorage = [Int32](repeating: 0, count: 3 * batch * seqLen)
        var ropeDeltas = [Int32](repeating: 0, count: batch)

        for b in 0 ..< batch {
            let row = inputIds[b].asArray(Int32.self).map(Int.init)

            var videoFlag = false
            var types: [TokenType] = []
            types.reserveCapacity(row.count)
            for token in row {
                if let videoStartTokenId, token == videoStartTokenId { videoFlag = true }
                if let videoEndTokenId, token == videoEndTokenId { videoFlag = false }

                if token == imageTokenId {
                    types.append(videoFlag ? .video : .image)
                } else {
                    types.append(.text)
                }
            }

            let groups = groupTypes(types)
            var maxPosition: Int = -1
            var imageGroupsSeen = 0

            var temporal = [Int32](repeating: 0, count: seqLen)
            var height = [Int32](repeating: 0, count: seqLen)
            var width = [Int32](repeating: 0, count: seqLen)

            for group in groups {
                let stIdx = maxPosition + 1
                let length = group.end - group.start

                switch group.type {
                case .text:
                    for i in 0 ..< length {
                        let value = Int32(stIdx + i)
                        let pos = group.start + i
                        temporal[pos] = value
                        height[pos] = value
                        width[pos] = value
                    }
                    maxPosition = stIdx + max(length - 1, 0)

                case .image:
                    imageGroupsSeen += 1
                    guard imageGroupsSeen == 1 else {
                        throw GLMOCRRoPEIndexError.multipleImagesNotSupported(requested: imageGroupsSeen)
                    }

                    let llmT = max(imageGridTHW.t, 1)
                    let llmH = max(imageGridTHW.h / max(spatialMergeSize, 1), 1)
                    let llmW = max(imageGridTHW.w / max(spatialMergeSize, 1), 1)
                    let expected = llmT * llmH * llmW
                    guard expected == length else {
                        throw GLMOCRRoPEIndexError.imageTokenCountMismatch(expected: expected, actual: length)
                    }

                    let perT = llmH * llmW
                    for i in 0 ..< length {
                        let pos = group.start + i
                        let t = i / perT
                        let rem = i % perT
                        let h = rem / llmW
                        let w = rem % llmW
                        temporal[pos] = Int32(stIdx + t)
                        height[pos] = Int32(stIdx + h)
                        width[pos] = Int32(stIdx + w)
                    }

                    maxPosition = stIdx + max(llmT - 1, llmH - 1, llmW - 1)

                case .video:
                    throw GLMOCRRoPEIndexError.videoNotImplemented
                }
            }

            ropeDeltas[b] = Int32(maxPosition + 1 - seqLen)

            let base = b * seqLen
            for i in 0 ..< seqLen {
                positionStorage[(0 * batch * seqLen) + base + i] = temporal[i]
                positionStorage[(1 * batch * seqLen) + base + i] = height[i]
                positionStorage[(2 * batch * seqLen) + base + i] = width[i]
            }
        }

        let positionIds = MLXArray(positionStorage, [3, batch, seqLen])
        let deltas = MLXArray(ropeDeltas.map { [$0] }.flatMap(\.self), [batch, 1])
        return Output(positionIds: positionIds, ropeDeltas: deltas)
    }

    private enum TokenType: Sendable {
        case text
        case image
        case video
    }

    private struct TypeGroup: Sendable {
        let type: TokenType
        let start: Int
        let end: Int
    }

    private static func groupTypes(_ types: [TokenType]) -> [TypeGroup] {
        guard !types.isEmpty else { return [] }
        var groups: [TypeGroup] = []
        groups.reserveCapacity(4)

        var current = types[0]
        var start = 0
        for i in 1 ..< types.count {
            if types[i] != current {
                groups.append(TypeGroup(type: current, start: start, end: i))
                current = types[i]
                start = i
            }
        }
        groups.append(TypeGroup(type: current, start: start, end: types.count))
        return groups
    }
}
