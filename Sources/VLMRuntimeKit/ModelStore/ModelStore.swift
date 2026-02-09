import Foundation
import Hub

public enum ModelStoreError: Error, Sendable {
    case invalidBaseDirectory(String)
    case snapshotFailed(String)
}

public struct ModelSnapshotRequest: Sendable, Equatable {
    public var modelID: String
    public var revision: String
    public var matchingGlobs: [String]

    public init(modelID: String, revision: String = "main", matchingGlobs: [String]) {
        self.modelID = modelID
        self.revision = revision
        self.matchingGlobs = matchingGlobs
    }
}

public protocol ModelStore: Sendable {
    func resolveSnapshot(
        _ request: ModelSnapshotRequest,
        downloadBase: URL?,
        progress: (@Sendable (Progress) -> Void)?
    ) async throws -> URL
}

/// Hugging Face Hub-backed store.
/// Mirrors the cache resolution logic used in reference Swift OCR repos.
public struct HuggingFaceHubModelStore: ModelStore {
    public init() {}

    public func resolveSnapshot(
        _ request: ModelSnapshotRequest,
        downloadBase: URL? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        let base = try Self.resolveHuggingFaceHubCacheDirectory(explicitBase: downloadBase)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let hub = HubApi(downloadBase: base, useOfflineMode: false)
        do {
            return try await hub.snapshot(from: request.modelID, revision: request.revision, matching: request.matchingGlobs) { p in
                progress?(p)
            }
        } catch {
            throw ModelStoreError.snapshotFailed(String(describing: error))
        }
    }

    public static func resolveHuggingFaceHubCacheDirectory(explicitBase: URL?) throws -> URL {
        if let explicitBase {
            guard explicitBase.isFileURL else { throw ModelStoreError.invalidBaseDirectory("downloadBase must be a file URL") }
            return explicitBase.standardizedFileURL
        }

        func normalize(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        }

        let env = ProcessInfo.processInfo.environment
        if let hubCache = normalize(env["HF_HUB_CACHE"]) {
            return URL(fileURLWithPath: hubCache).standardizedFileURL
        }
        if let hfHome = normalize(env["HF_HOME"]) {
            return URL(fileURLWithPath: hfHome).appendingPathComponent("hub").standardizedFileURL
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cache/huggingface/hub").standardizedFileURL
    }
}
