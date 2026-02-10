import Foundation

public enum PPDocLayoutV3ConfigError: Error, Sendable, Equatable {
    case invalidID2LabelKey(String)
}

/// Minimal model config for PP-DocLayout-V3 (Transformers `config.json`).
///
/// This is intentionally small: only fields required by later layout stages
/// (e.g. mapping predicted class IDs to native label strings).
public struct PPDocLayoutV3Config: Sendable, Codable, Equatable {
    public var modelType: String?
    public var numLabels: Int?
    public var id2label: [Int: String]
    public var label2id: [String: Int]?

    public init(
        modelType: String? = nil,
        numLabels: Int? = nil,
        id2label: [Int: String],
        label2id: [String: Int]? = nil
    ) {
        self.modelType = modelType
        self.numLabels = numLabels
        self.id2label = id2label
        self.label2id = label2id
    }

    private enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case numLabels = "num_labels"
        case id2label
        case label2id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        modelType = try container.decodeIfPresent(String.self, forKey: .modelType)
        numLabels = try container.decodeIfPresent(Int.self, forKey: .numLabels)
        label2id = try container.decodeIfPresent([String: Int].self, forKey: .label2id)

        let raw = try container.decode([String: String].self, forKey: .id2label)
        var parsed: [Int: String] = [:]
        parsed.reserveCapacity(raw.count)
        for (key, value) in raw {
            guard let id = Int(key) else { throw PPDocLayoutV3ConfigError.invalidID2LabelKey(key) }
            parsed[id] = value
        }
        id2label = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(modelType, forKey: .modelType)
        try container.encodeIfPresent(numLabels, forKey: .numLabels)
        try container.encodeIfPresent(label2id, forKey: .label2id)

        var raw: [String: String] = [:]
        raw.reserveCapacity(id2label.count)
        for (key, value) in id2label {
            raw[String(key)] = value
        }
        try container.encode(raw, forKey: .id2label)
    }

    public static func load(from modelFolder: URL) throws -> PPDocLayoutV3Config {
        let url = modelFolder.appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PPDocLayoutV3Config.self, from: data)
    }
}
