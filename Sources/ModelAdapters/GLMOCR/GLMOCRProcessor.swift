import Foundation
import VLMRuntimeKit

public enum GLMOCRProcessorError: Error, Sendable {
    case notImplemented
}

/// Model-specific “policy” layer:
/// - maps OCRTask to a GLM-OCR chat prompt
/// - owns any vision preprocessing constants (smart resize, tiling, token budgeting)
public struct GLMOCRProcessor: Sendable {
    public var promptTemplate: PromptTemplate

    public init(promptTemplate: PromptTemplate = .init(imagePlaceholder: "<image>")) {
        self.promptTemplate = promptTemplate
    }

    public func makePrompt(for task: OCRTask) -> String {
        // Starter: keep a simple “image + instruction” prompt.
        // Phase 03+ should align exactly with GLM-OCR’s expected chat template / special tokens.
        let instruction = promptTemplate.instruction(for: task)
        return "\(promptTemplate.imagePlaceholder)\(instruction)"
    }
}
