import Foundation

struct PPDocLayoutV3ForwardGoldenFixture: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        let fixtureVersion: String
        let modelId: String?
        let snapshotHash: String?
        let source: String?
        let torchVersion: String?
        let transformersVersion: String?
        let device: String?
        let dtype: String?
        let pixelLayout: String?
        let generatedAt: String?

        enum CodingKeys: String, CodingKey {
            case fixtureVersion = "fixture_version"
            case modelId = "model_id"
            case snapshotHash = "snapshot_hash"
            case source
            case torchVersion = "torch_version"
            case transformersVersion = "transformers_version"
            case device
            case dtype
            case pixelLayout = "pixel_layout"
            case generatedAt = "generated_at"
        }
    }

    struct ProcessorSummary: Decodable, Sendable {
        let imageSize: Int
        let doResize: Bool
        let doRescale: Bool
        let rescaleFactor: Float
        let doNormalize: Bool
        let imageMean: [Float]
        let imageStd: [Float]

        enum CodingKeys: String, CodingKey {
            case imageSize = "image_size"
            case doResize = "do_resize"
            case doRescale = "do_rescale"
            case rescaleFactor = "rescale_factor"
            case doNormalize = "do_normalize"
            case imageMean = "image_mean"
            case imageStd = "image_std"
        }
    }

    struct ModelSummary: Decodable, Sendable {
        let numQueries: Int
        let numLabels: Int
        let logitsShape: [Int]
        let predBoxesShape: [Int]

        enum CodingKeys: String, CodingKey {
            case numQueries = "num_queries"
            case numLabels = "num_labels"
            case logitsShape = "logits_shape"
            case predBoxesShape = "pred_boxes_shape"
        }
    }

    let metadata: Metadata
    let processor: ProcessorSummary
    let model: ModelSummary

    let queryIndices: [Int]
    let classIndices: [Int]
    let logitsSlice: [[Float]]
    let predBoxesSlice: [[Float]]

    enum CodingKeys: String, CodingKey {
        case metadata
        case processor
        case model
        case queryIndices = "query_indices"
        case classIndices = "class_indices"
        case logitsSlice = "logits_slice"
        case predBoxesSlice = "pred_boxes_slice"
    }
}
