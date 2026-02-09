import Foundation
import MLX

public enum WeightsError: Error, Sendable {
    case invalidURL(URL)
    case cannotEnumerate(URL)
    case noSafetensorsFound(URL)
    case duplicateTensorKey(String)
    case loadFailed(URL, String)
}

/// Minimal safetensors loader (directory or single file).
///
/// Notes:
/// - This is intentionally model-agnostic.
/// - Model-specific key mapping / transforms should live in model adapters.
public struct WeightsLoader: Sendable {
    public init() {}

    public func loadAll(from url: URL, dtype: DType? = nil) throws -> [String: MLXArray] {
        guard url.isFileURL else { throw WeightsError.invalidURL(url) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WeightsError.invalidURL(url)
        }

        if isDirectory.boolValue {
            return try loadAllFromDirectory(url, dtype: dtype)
        }

        if url.pathExtension == "safetensors" {
            return try loadAllFromSafetensorsFile(url, dtype: dtype)
        }

        throw WeightsError.invalidURL(url)
    }

    private func loadAllFromSafetensorsFile(_ url: URL, dtype: DType?) throws -> [String: MLXArray] {
        do {
            var arrays = try MLX.loadArrays(url: url)
            if let dtype {
                for (k, v) in arrays {
                    arrays[k] = v.asType(dtype)
                }
            }
            return arrays
        } catch {
            throw WeightsError.loadFailed(url, String(describing: error))
        }
    }

    private func loadAllFromDirectory(_ url: URL, dtype: DType?) throws -> [String: MLXArray] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            throw WeightsError.cannotEnumerate(url)
        }

        var safetensorsFiles: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "safetensors" {
            safetensorsFiles.append(fileURL)
        }

        guard !safetensorsFiles.isEmpty else { throw WeightsError.noSafetensorsFound(url) }

        var combined: [String: MLXArray] = [:]
        for fileURL in safetensorsFiles.sorted(by: { $0.path < $1.path }) {
            let loaded = try loadAllFromSafetensorsFile(fileURL, dtype: dtype)
            for (k, v) in loaded {
                if combined[k] != nil {
                    throw WeightsError.duplicateTensorKey(k)
                }
                combined[k] = v
            }
        }

        return combined
    }
}
