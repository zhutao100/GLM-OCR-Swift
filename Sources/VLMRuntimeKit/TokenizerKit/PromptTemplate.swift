import Foundation

public enum TokenizerKitError: Error, Sendable {
    case missingImagePlaceholder
}

/// Lightweight prompt/template utilities.
/// The intent is to keep this model-agnostic and testable.
public struct PromptTemplate: Sendable, Equatable {
    public var imagePlaceholder: String

    public init(imagePlaceholder: String = "<image>") {
        self.imagePlaceholder = imagePlaceholder
    }

    /// Split a prompt into [prefix, suffix] around the image placeholder.
    public func splitByImagePlaceholder(_ prompt: String) throws -> (prefix: String, suffix: String) {
        guard let range = prompt.range(of: imagePlaceholder) else {
            throw TokenizerKitError.missingImagePlaceholder
        }
        let prefix = String(prompt[..<range.lowerBound])
        let suffix = String(prompt[range.upperBound...])
        return (prefix, suffix)
    }

    /// Map an OCRTask into a user-facing prompt instruction string.
    /// Adapters are expected to compose this into the model's chat template.
    public func instruction(for task: OCRTask) -> String {
        switch task {
        case .text:
            "Extract the text and return as Markdown."
        case .formula:
            "Extract formulas. Prefer LaTeX for math."
        case .table:
            "Extract tables. Prefer Markdown tables."
        case let .structuredJSON(schema):
            "Extract structured data and return JSON that matches this schema:\n\n\(schema)"
        }
    }
}
