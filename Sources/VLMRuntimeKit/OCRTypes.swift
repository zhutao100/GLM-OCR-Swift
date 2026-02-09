import Foundation

// MARK: - Public API surface (intentionally small)

public protocol OCRPipeline: Sendable {
    associatedtype Input
    func recognize(_ input: Input, task: OCRTask, options: GenerateOptions) async throws -> OCRResult
}

public enum OCRTask: Sendable, Equatable {
    case text
    case formula
    case table
    case structuredJSON(schema: String)
}

public struct GenerateOptions: Sendable, Equatable {
    public var maxNewTokens: Int
    public var temperature: Float
    public var topP: Float

    public init(maxNewTokens: Int = 2048, temperature: Float = 0, topP: Float = 1) {
        self.maxNewTokens = maxNewTokens
        self.temperature = temperature
        self.topP = topP
    }
}

public struct Diagnostics: Sendable, Equatable {
    public var modelID: String?
    public var revision: String?
    public var timings: [String: Double]
    public var notes: [String]

    public init(modelID: String? = nil, revision: String? = nil, timings: [String: Double] = [:], notes: [String] = []) {
        self.modelID = modelID
        self.revision = revision
        self.timings = timings
        self.notes = notes
    }
}

public struct OCRResult: Sendable, Equatable {
    public var text: String
    public var rawTokens: [Int]?
    public var diagnostics: Diagnostics

    public init(text: String, rawTokens: [Int]? = nil, diagnostics: Diagnostics = .init()) {
        self.text = text
        self.rawTokens = rawTokens
        self.diagnostics = diagnostics
    }
}
