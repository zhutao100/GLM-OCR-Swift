import Foundation

public struct GLMOCRConfig: Sendable, Codable, Equatable {
    public var modelType: String?
    public var vocabSize: Int?
    public var hiddenSize: Int?
    public var maxPositionEmbeddings: Int?

    public init(modelType: String? = nil, vocabSize: Int? = nil, hiddenSize: Int? = nil, maxPositionEmbeddings: Int? = nil) {
        self.modelType = modelType
        self.vocabSize = vocabSize
        self.hiddenSize = hiddenSize
        self.maxPositionEmbeddings = maxPositionEmbeddings
    }

    public static func load(from modelFolder: URL) throws -> GLMOCRConfig {
        let url = modelFolder.appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GLMOCRConfig.self, from: data)
    }
}
