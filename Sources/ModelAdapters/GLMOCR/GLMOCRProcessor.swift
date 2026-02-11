import Foundation
import VLMRuntimeKit

/// Model-specific “policy” layer:
/// - maps OCRTask to a GLM-OCR chat prompt
/// - owns any vision preprocessing constants (smart resize, tiling, token budgeting)
public struct GLMOCRProcessor: Sendable {
    /// The prompt placeholder used by `GLMOCRChatTemplate` to insert the correct number of `<|image|>` tokens.
    public var imagePlaceholder: String

    /// Default instruction used when no task-specific prompt is available.
    ///
    /// Mirrors `glmocr/config.yaml` (`page_loader.default_prompt`).
    public var defaultPrompt: String

    /// Task-specific prompts used in layout mode.
    ///
    /// Mirrors `glmocr/config.yaml` (`page_loader.task_prompt_mapping`).
    public var taskPromptMapping: [OCRTask: String]

    public init(
        imagePlaceholder: String = "<image>",
        defaultPrompt: String = Self.officialDefaultPrompt,
        taskPromptMapping: [OCRTask: String] = Self.officialTaskPromptMapping
    ) {
        self.imagePlaceholder = imagePlaceholder
        self.defaultPrompt = defaultPrompt
        self.taskPromptMapping = taskPromptMapping
    }

    public func makePrompt(for task: OCRTask) -> String {
        let instruction: String = switch task {
        case .text, .table, .formula:
            taskPromptMapping[task] ?? defaultPrompt
        case let .structuredJSON(schema):
            "Extract structured data and return JSON that matches this schema:\n\n\(schema)"
        }

        return "\(imagePlaceholder)\n\(instruction)"
    }
}

public extension GLMOCRProcessor {
    static let officialDefaultPrompt: String =
        "Recognize the text in the image and output in Markdown format.\n" +
        "Preserve the original layout (headings/paragraphs/tables/formulas).\n" +
        "Do not fabricate content that does not exist in the image."

    static let officialTaskPromptMapping: [OCRTask: String] = [
        .text: "Text Recognition:",
        .table: "Table Recognition:",
        .formula: "Formula Recognition:",
    ]
}
