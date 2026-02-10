import Foundation

struct GLMOCRForwardGoldenFixture: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        let fixtureVersion: String
        let modelId: String?
        let snapshotHash: String?
        let source: String?
        let pixelLayout: String?
        let generatedAt: String?

        enum CodingKeys: String, CodingKey {
            case fixtureVersion = "fixture_version"
            case modelId = "model_id"
            case snapshotHash = "snapshot_hash"
            case source
            case pixelLayout = "pixel_layout"
            case generatedAt = "generated_at"
        }
    }

    struct ConfigSummary: Decodable, Sendable {
        let vocabSize: Int
        let imageSize: Int
        let patchSize: Int
        let mergeSize: Int
        let temporalPatchSize: Int

        enum CodingKeys: String, CodingKey {
            case vocabSize = "vocab_size"
            case imageSize = "image_size"
            case patchSize = "patch_size"
            case mergeSize = "merge_size"
            case temporalPatchSize = "temporal_patch_size"
        }
    }

    struct Derived: Decodable, Sendable {
        let numImageTokens: Int
        let seqLen: Int

        enum CodingKeys: String, CodingKey {
            case numImageTokens = "num_image_tokens"
            case seqLen = "seq_len"
        }
    }

    struct TokenIDs: Decodable, Sendable {
        let padId: Int
        let eosId: Int
        let gMaskId: Int
        let sopId: Int
        let systemId: Int
        let userId: Int
        let assistantId: Int
        let beginImageId: Int
        let imageId: Int
        let endImageId: Int

        enum CodingKeys: String, CodingKey {
            case padId = "pad_id"
            case eosId = "eos_id"
            case gMaskId = "gmask_id"
            case sopId = "sop_id"
            case systemId = "system_id"
            case userId = "user_id"
            case assistantId = "assistant_id"
            case beginImageId = "begin_image_id"
            case imageId = "image_id"
            case endImageId = "end_image_id"
        }
    }

    let metadata: Metadata
    let config: ConfigSummary
    let derived: Derived
    let tokenIDs: TokenIDs
    let prompt: String

    let topKLast: [Int]
    let positions: [Int]
    let vocabIndices: [Int]
    let logitsSlice: [[Float]]

    enum CodingKeys: String, CodingKey {
        case metadata
        case config
        case derived
        case tokenIDs = "token_ids"
        case prompt
        case topKLast = "topk_last"
        case positions
        case vocabIndices = "vocab_indices"
        case logitsSlice = "logits_slice"
    }
}
