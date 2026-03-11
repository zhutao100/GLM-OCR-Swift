import Foundation
import Hub

public enum ModelStoreError: Error, Sendable {
    case invalidBaseDirectory(String)
    case cannotCreateCacheDirectory(URL, String)
    case snapshotFailed(modelID: String, revision: String, underlying: String)
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

public extension ModelStore {
    func resolveSnapshotPreferringExisting(
        _ request: ModelSnapshotRequest,
        explicitSnapshotPath: String? = nil,
        downloadBase: URL? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        if self is HuggingFaceHubModelStore {
            return try await HuggingFaceHubModelStore.resolveSnapshotPreferringExisting(
                request,
                explicitSnapshotPath: explicitSnapshotPath,
                downloadBase: downloadBase,
                downloadStore: self,
                progress: progress
            )
        }

        return try await resolveSnapshot(request, downloadBase: downloadBase, progress: progress)
    }
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
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            throw ModelStoreError.cannotCreateCacheDirectory(base, String(describing: error))
        }

        let hub = HubApi(downloadBase: base, useOfflineMode: false)
        do {
            return try await hub.snapshot(
                from: request.modelID, revision: request.revision, matching: request.matchingGlobs
            ) { p in
                progress?(p)
            }
        } catch {
            throw ModelStoreError.snapshotFailed(
                modelID: request.modelID,
                revision: request.revision,
                underlying: String(describing: error)
            )
        }
    }

    public static func resolveHuggingFaceHubCacheDirectory(explicitBase: URL?) throws -> URL {
        try resolveHuggingFaceHubCacheDirectory(
            explicitBase: explicitBase,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func resolveHuggingFaceHubCacheDirectory(
        explicitBase: URL?,
        environment: [String: String],
        homeDirectory: URL
    ) throws -> URL {
        if let explicitBase {
            guard explicitBase.isFileURL else {
                throw ModelStoreError.invalidBaseDirectory("downloadBase must be a file URL")
            }
            return explicitBase.standardizedFileURL
        }

        func normalizePath(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }

            if trimmed == "~" { return homeDirectory.path }
            if trimmed.hasPrefix("~/") {
                return homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2))).path
            }
            return trimmed
        }

        if let hubCache = normalizePath(environment["HF_HUB_CACHE"]) {
            return URL(fileURLWithPath: hubCache).standardizedFileURL
        }
        if let hfHome = normalizePath(environment["HF_HOME"]) {
            return URL(fileURLWithPath: hfHome).appendingPathComponent("hub").standardizedFileURL
        }

        return homeDirectory.appendingPathComponent(".cache/huggingface/hub").standardizedFileURL
    }
}

extension HuggingFaceHubModelStore {
    public static func resolveExplicitSnapshotPath(_ rawPath: String?) -> URL? {
        let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Resolves an already-present snapshot using the repo's preferred local lookup order:
    /// explicit snapshot path override first, then the local HF cache.
    public static func resolveExistingSnapshot(
        _ request: ModelSnapshotRequest,
        explicitSnapshotPath: String? = nil,
        downloadBase: URL? = nil
    ) throws -> URL? {
        if let explicitSnapshotURL = resolveExplicitSnapshotPath(explicitSnapshotPath) {
            return explicitSnapshotURL
        }

        return try resolveCachedSnapshot(
            modelID: request.modelID,
            revision: request.revision,
            downloadBase: downloadBase
        )
    }

    /// Resolves a snapshot by preferring existing local sources before downloading:
    /// explicit snapshot path override, then the local HF cache, then the provided download store.
    public static func resolveSnapshotPreferringExisting(
        _ request: ModelSnapshotRequest,
        explicitSnapshotPath: String? = nil,
        downloadBase: URL? = nil,
        downloadStore: any ModelStore = HuggingFaceHubModelStore(),
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        if let existingSnapshot = try resolveExistingSnapshot(
            request,
            explicitSnapshotPath: explicitSnapshotPath,
            downloadBase: downloadBase
        ) {
            return existingSnapshot
        }

        return try await downloadStore.resolveSnapshot(request, downloadBase: downloadBase, progress: progress)
    }

    /// Resolves a local Hugging Face Hub snapshot folder without downloading.
    ///
    /// This is intended for opt-in integration tests and parity checks that should be able to
    /// auto-discover an existing cached snapshot on the current machine.
    ///
    /// - Parameters:
    ///   - modelID: The HF model ID (e.g. `org/name`).
    ///   - revision: The revision to resolve (typically `main`).
    ///   - downloadBase: Optional explicit hub cache directory (the `.../huggingface/hub` folder).
    /// - Returns: The resolved local snapshot folder, or `nil` if no cached snapshot is present.
    public static func resolveCachedSnapshot(
        modelID: String,
        revision: String = "main",
        downloadBase: URL? = nil
    ) throws -> URL? {
        let hubCache = try resolveHuggingFaceHubCacheDirectory(explicitBase: downloadBase)
        return resolveCachedSnapshot(modelID: modelID, revision: revision, hubCache: hubCache)
    }

    static func resolveCachedSnapshot(
        modelID: String,
        revision: String,
        hubCache: URL
    ) -> URL? {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRevision = revision.trimmingCharacters(in: .whitespacesAndNewlines)

        let modelDirName = "models--" + normalizedModelID.replacingOccurrences(of: "/", with: "--")
        let modelDir = hubCache.appendingPathComponent(modelDirName, isDirectory: true)

        func appendingComponents(_ base: URL, _ path: String) -> URL {
            let parts = path.split(separator: "/").map(String.init)
            return parts.reduce(base) { $0.appendingPathComponent($1, isDirectory: false) }
        }

        func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }

        func readRefSnapshotID() -> String? {
            let refsDir = modelDir.appendingPathComponent("refs", isDirectory: true)
            let refFile = appendingComponents(refsDir, normalizedRevision)
            guard let data = FileManager.default.contents(atPath: refFile.path),
                let text = String(data: data, encoding: .utf8)
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let snapshotsDir = modelDir.appendingPathComponent("snapshots", isDirectory: true)

        if let snapshotID = readRefSnapshotID() {
            let candidate = snapshotsDir.appendingPathComponent(snapshotID, isDirectory: true)
            if isDirectory(candidate) { return candidate.standardizedFileURL }
        }

        guard isDirectory(snapshotsDir) else { return nil }

        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: snapshotsDir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return nil }

        var bestURL: URL?
        var bestDate = Date.distantPast

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date.distantPast
            if date > bestDate {
                bestDate = date
                bestURL = entry.standardizedFileURL
            }
        }

        return bestURL
    }
}
