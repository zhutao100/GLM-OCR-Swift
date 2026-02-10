import Foundation

public enum PPDocLayoutV3WeightsError: Error, Sendable, Equatable {
    case invalidURL(URL)
    case cannotEnumerate(URL)
    case noSafetensorsFound(URL)
    case invalidSafetensorsHeader(URL, String)
    case duplicateTensorKey(String)
    case missingRequiredKeys([String])
    case invalidTensorShape(key: String, shape: [Int])
}

public enum PPDocLayoutV3Weights {
    public struct TensorInfo: Sendable, Equatable {
        public var dtype: String
        public var shape: [Int]

        public init(dtype: String, shape: [Int]) {
            self.dtype = dtype
            self.shape = shape
        }
    }

    public struct Inventory: Sendable, Equatable {
        public var tensors: [String: TensorInfo]
        public var safetensorsFiles: [URL]

        public init(tensors: [String: TensorInfo], safetensorsFiles: [URL]) {
            self.tensors = tensors
            self.safetensorsFiles = safetensorsFiles
        }
    }

    /// Minimal key presence checks to ensure the snapshot is structurally usable.
    ///
    /// These keys were extracted from the reference snapshot of:
    /// `PaddlePaddle/PP-DocLayoutV3_safetensors` (`model.safetensors`).
    public static let requiredKeys: [String] = [
        // Backbone stem (RGB input conv).
        "model.backbone.model.embedder.stem1.convolution.weight",

        // Encoder conv + first transformer block.
        "model.encoder.downsample_convs.0.conv.weight",
        "model.encoder.encoder.0.layers.0.self_attn.q_proj.weight",

        // Decoder self-attention + cross-attention.
        "model.decoder.layers.0.self_attn.q_proj.weight",
        "model.decoder.layers.0.encoder_attn.value_proj.weight",

        // Detection heads.
        "model.enc_score_head.weight",
        "model.enc_bbox_head.layers.0.weight",
    ]

    public static func loadInventory(from modelFolder: URL) throws -> Inventory {
        let resolvedURL = modelFolder.resolvingSymlinksInPath()
        guard resolvedURL.isFileURL else { throw PPDocLayoutV3WeightsError.invalidURL(modelFolder) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PPDocLayoutV3WeightsError.invalidURL(resolvedURL)
        }

        guard let enumerator = FileManager.default.enumerator(at: resolvedURL, includingPropertiesForKeys: nil) else {
            throw PPDocLayoutV3WeightsError.cannotEnumerate(resolvedURL)
        }

        var safetensorsFiles: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "safetensors" {
            safetensorsFiles.append(fileURL)
        }
        safetensorsFiles.sort { $0.path < $1.path }

        guard !safetensorsFiles.isEmpty else { throw PPDocLayoutV3WeightsError.noSafetensorsFound(resolvedURL) }

        var combined: [String: TensorInfo] = [:]
        for fileURL in safetensorsFiles {
            let tensors = try SafetensorsHeader.load(from: fileURL).tensors
            for (key, info) in tensors {
                if combined[key] != nil {
                    throw PPDocLayoutV3WeightsError.duplicateTensorKey(key)
                }
                combined[key] = info
            }
        }

        return Inventory(tensors: combined, safetensorsFiles: safetensorsFiles)
    }

    public static func validate(_ inventory: Inventory) throws {
        let missing = requiredKeys.filter { inventory.tensors[$0] == nil }
        if !missing.isEmpty {
            throw PPDocLayoutV3WeightsError.missingRequiredKeys(missing)
        }

        for key in requiredKeys {
            guard let info = inventory.tensors[key] else { continue }
            if info.shape.isEmpty || info.shape.contains(where: { $0 <= 0 }) {
                throw PPDocLayoutV3WeightsError.invalidTensorShape(key: key, shape: info.shape)
            }
        }

        if let stem = inventory.tensors["model.backbone.model.embedder.stem1.convolution.weight"] {
            if stem.shape.count != 4 || stem.shape[1] != 3 {
                throw PPDocLayoutV3WeightsError.invalidTensorShape(
                    key: "model.backbone.model.embedder.stem1.convolution.weight",
                    shape: stem.shape
                )
            }
        }
    }
}

private enum SafetensorsHeader {
    struct Parsed: Sendable, Equatable {
        var tensors: [String: PPDocLayoutV3Weights.TensorInfo]
    }

    static func load(from url: URL) throws -> Parsed {
        let resolvedURL = url.resolvingSymlinksInPath()
        guard resolvedURL.isFileURL else { throw PPDocLayoutV3WeightsError.invalidURL(url) }

        let handle = try FileHandle(forReadingFrom: resolvedURL)
        defer { try? handle.close() }

        guard let lengthData = try handle.read(upToCount: 8), lengthData.count == 8 else {
            throw PPDocLayoutV3WeightsError.invalidSafetensorsHeader(resolvedURL, "missing header length")
        }

        let headerLength: UInt64 = lengthData.withUnsafeBytes { ptr in
            UInt64(littleEndian: ptr.loadUnaligned(as: UInt64.self))
        }

        if headerLength == 0 || headerLength > 32 * 1024 * 1024 {
            throw PPDocLayoutV3WeightsError.invalidSafetensorsHeader(resolvedURL, "invalid header length \(headerLength)")
        }

        guard let headerData = try handle.read(upToCount: Int(headerLength)), headerData.count == Int(headerLength) else {
            throw PPDocLayoutV3WeightsError.invalidSafetensorsHeader(resolvedURL, "truncated header")
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: headerData)
        } catch {
            throw PPDocLayoutV3WeightsError.invalidSafetensorsHeader(resolvedURL, "JSON parse failed: \(error)")
        }

        guard let dict = json as? [String: Any] else {
            throw PPDocLayoutV3WeightsError.invalidSafetensorsHeader(resolvedURL, "header JSON is not an object")
        }

        var tensors: [String: PPDocLayoutV3Weights.TensorInfo] = [:]
        tensors.reserveCapacity(dict.count)

        for (key, value) in dict where key != "__metadata__" {
            guard let info = value as? [String: Any] else { continue }
            guard let dtype = info["dtype"] as? String else { continue }
            guard let shapeAny = info["shape"] as? [Any] else { continue }

            var shape: [Int] = []
            shape.reserveCapacity(shapeAny.count)
            for dimAny in shapeAny {
                if let dim = dimAny as? Int {
                    shape.append(dim)
                } else if let dim = dimAny as? NSNumber {
                    shape.append(dim.intValue)
                }
            }

            tensors[key] = PPDocLayoutV3Weights.TensorInfo(dtype: dtype, shape: shape)
        }

        return Parsed(tensors: tensors)
    }
}
