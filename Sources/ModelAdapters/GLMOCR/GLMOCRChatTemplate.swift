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

        let imageTokens = String(repeating: "<|image|>", count: numImageTokens)

        var rendered = "[gMASK]<sop>\n<|user|>\n"
        if !prefix.isEmpty {
            rendered += prefix
        }

        rendered += "<|begin_of_image|>"
        rendered += imageTokens
        rendered += "<|end_of_image|>"

        if !suffix.isEmpty {
            rendered += suffix
        }

        if appendNoThink {
            rendered += "\n/nothink"
        }

        rendered += "\n<|assistant|>\n"

        return tokenizer.tokenizer.encode(text: rendered, addSpecialTokens: false)
    }
}
