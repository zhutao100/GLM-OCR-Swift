import Foundation

// MARK: - Public API surface (intentionally small)

public protocol OCRPipeline: Sendable {
    associatedtype Input: Sendable
    func recognize(_ input: Input, task: OCRTask, options: GenerateOptions) async throws -> OCRResult
}

public enum OCRTask: Sendable, Equatable, Hashable {
    case text
    case formula
    case table
    case structuredJSON(schema: String)
}

public enum GenerationPreset: String, Sendable, Codable, CaseIterable {
    case defaultGreedyV1 = "default-greedy-v1"
    case parityGreedyV1 = "parity-greedy-v1"

    public var temperature: Float { 0 }
    public var topP: Float { 1 }
}

public struct GenerateOptions: Sendable, Equatable {
    public var maxNewTokens: Int
    public var temperature: Float
    public var topP: Float
    public var preset: GenerationPreset

    public init(maxNewTokens: Int = 2048, temperature: Float = 0, topP: Float = 1) {
        self.init(
            maxNewTokens: maxNewTokens,
            temperature: temperature,
            topP: topP,
            preset: .defaultGreedyV1
        )
    }

    public init(
        maxNewTokens: Int = 2048,
        temperature: Float = 0,
        topP: Float = 1,
        preset: GenerationPreset
    ) {
        self.maxNewTokens = maxNewTokens
        self.temperature = temperature
        self.topP = topP
        self.preset = preset
    }

    public static func preset(_ preset: GenerationPreset, maxNewTokens: Int = 2048) -> Self {
        Self(
            maxNewTokens: maxNewTokens,
            temperature: preset.temperature,
            topP: preset.topP,
            preset: preset
        )
    }
}

public struct Diagnostics: Sendable, Codable, Equatable {
    public var modelID: String?
    public var revision: String?
    public var timings: [String: Double]
    public var notes: [String]

    public init(modelID: String? = nil, revision: String? = nil, timings: [String: Double] = [:], notes: [String] = [])
    {
        self.modelID = modelID
        self.revision = revision
        self.timings = timings
        self.notes = notes
    }
}

public struct OCRResult: Sendable, Codable, Equatable {
    public var text: String
    public var rawTokens: [Int]?
    /// Optional structured output (pages/regions/bboxes).
    public var document: OCRDocument?
    public var diagnostics: Diagnostics

    public init(text: String, rawTokens: [Int]? = nil, document: OCRDocument? = nil, diagnostics: Diagnostics = .init())
    {
        self.text = text
        self.rawTokens = rawTokens
        self.document = document
        self.diagnostics = diagnostics
    }
}
