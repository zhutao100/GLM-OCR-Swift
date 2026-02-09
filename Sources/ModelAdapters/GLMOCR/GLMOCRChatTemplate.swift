import Foundation
import Tokenizers
import VLMRuntimeKit

public enum GLMOCRChatTemplateError: Error, Sendable {
    case invalidImageTokenCount(Int)
}

public struct GLMOCRChatTemplate: Sendable {
    public var imagePlaceholder: String
    public var appendNoThink: Bool

    public init(imagePlaceholder: String = "<image>", appendNoThink: Bool = true) {
        self.imagePlaceholder = imagePlaceholder
        self.appendNoThink = appendNoThink
    }

    public func buildInputIDs(
        prompt: String,
        tokenizer: GLMOCRTokenizer,
        numImageTokens: Int
    ) throws -> [Int] {
        guard numImageTokens > 0 else { throw GLMOCRChatTemplateError.invalidImageTokenCount(numImageTokens) }

        let template = PromptTemplate(imagePlaceholder: imagePlaceholder)
        let (prefix, suffix) = try template.splitByImagePlaceholder(prompt)
        let ids = tokenizer.specialTokenIDs

        func encode(_ text: String) -> [Int] {
            tokenizer.tokenizer.encode(text: text, addSpecialTokens: false)
        }

        var inputIds: [Int] = []
        inputIds.append(ids.gMaskId)
        inputIds.append(ids.sopId)
        inputIds.append(contentsOf: encode("\n"))

        inputIds.append(ids.userId)
        inputIds.append(contentsOf: encode("\n"))
        if !prefix.isEmpty {
            inputIds.append(contentsOf: encode(prefix))
        }

        inputIds.append(ids.beginImageId)
        inputIds.append(contentsOf: Array(repeating: ids.imageId, count: numImageTokens))
        inputIds.append(ids.endImageId)

        if !suffix.isEmpty {
            inputIds.append(contentsOf: encode(suffix))
        }

        if appendNoThink {
            inputIds.append(contentsOf: encode("\n/nothink"))
        }

        inputIds.append(contentsOf: encode("\n"))
        inputIds.append(ids.assistantId)
        inputIds.append(contentsOf: encode("\n"))

        return inputIds
    }
}
