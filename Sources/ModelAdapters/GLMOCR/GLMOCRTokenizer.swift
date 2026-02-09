import Foundation
import Tokenizers

public enum GLMOCRTokenizerError: Error, Sendable {
    case missingToken(String)
    case mismatchedTokenID(token: String, expected: Int, actual: Int)
    case missingConfigValue(String)
}

public struct GLMOCRSpecialTokenIDs: Sendable, Equatable {
    public var gMaskId: Int
    public var sopId: Int
    public var systemId: Int
    public var userId: Int
    public var assistantId: Int

    public var beginImageId: Int
    public var imageId: Int
    public var endImageId: Int

    public var eosId: Int
    public var padId: Int

    public init(
        gMaskId: Int,
        sopId: Int,
        systemId: Int,
        userId: Int,
        assistantId: Int,
        beginImageId: Int,
        imageId: Int,
        endImageId: Int,
        eosId: Int,
        padId: Int
    ) {
        self.gMaskId = gMaskId
        self.sopId = sopId
        self.systemId = systemId
        self.userId = userId
        self.assistantId = assistantId
        self.beginImageId = beginImageId
        self.imageId = imageId
        self.endImageId = endImageId
        self.eosId = eosId
        self.padId = padId
    }
}

public struct GLMOCRTokenizer: Sendable {
    public let tokenizer: any Tokenizer
    public let specialTokenIDs: GLMOCRSpecialTokenIDs

    public init(tokenizer: any Tokenizer, specialTokenIDs: GLMOCRSpecialTokenIDs) {
        self.tokenizer = tokenizer
        self.specialTokenIDs = specialTokenIDs
    }

    public static func load(from modelFolder: URL, config: GLMOCRConfig) async throws -> GLMOCRTokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder, strict: true)

        func requireID(_ token: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(token) else {
                throw GLMOCRTokenizerError.missingToken(token)
            }
            return id
        }

        guard let eosId = tokenizer.eosTokenId else {
            throw GLMOCRTokenizerError.missingConfigValue("tokenizer.eosTokenId")
        }
        guard let padId = config.textConfig.padTokenId else {
            throw GLMOCRTokenizerError.missingConfigValue("text_config.pad_token_id")
        }

        let ids = try GLMOCRSpecialTokenIDs(
            gMaskId: requireID("[gMASK]"),
            sopId: requireID("<sop>"),
            systemId: requireID("<|system|>"),
            userId: requireID("<|user|>"),
            assistantId: requireID("<|assistant|>"),
            beginImageId: requireID("<|begin_of_image|>"),
            imageId: requireID("<|image|>"),
            endImageId: requireID("<|end_of_image|>"),
            eosId: eosId,
            padId: padId
        )

        if let expected = config.imageStartTokenId, expected != ids.beginImageId {
            throw GLMOCRTokenizerError.mismatchedTokenID(
                token: "<|begin_of_image|>",
                expected: expected,
                actual: ids.beginImageId
            )
        }
        if let expected = config.imageTokenId, expected != ids.imageId {
            throw GLMOCRTokenizerError.mismatchedTokenID(token: "<|image|>", expected: expected, actual: ids.imageId)
        }
        if let expected = config.imageEndTokenId, expected != ids.endImageId {
            throw GLMOCRTokenizerError.mismatchedTokenID(
                token: "<|end_of_image|>",
                expected: expected,
                actual: ids.endImageId
            )
        }

        let endOfTextId = try requireID("<|endoftext|>")
        if endOfTextId != ids.padId {
            throw GLMOCRTokenizerError.mismatchedTokenID(token: "<|endoftext|>", expected: ids.padId, actual: endOfTextId)
        }

        return GLMOCRTokenizer(tokenizer: tokenizer, specialTokenIDs: ids)
    }
}
