import XCTest

@testable import VLMRuntimeKit

final class ModelStoreTests: XCTestCase {
    private enum TestError: Error {
        case unexpectedDownload
    }

    private struct FailingModelStore: ModelStore {
        func resolveSnapshot(
            _ request: ModelSnapshotRequest,
            downloadBase _: URL?,
            progress _: (@Sendable (Progress) -> Void)?
        ) async throws -> URL {
            XCTFail("Unexpected download fallback for \(request.modelID)")
            throw TestError.unexpectedDownload
        }
    }

    private struct StaticModelStore: ModelStore {
        let snapshotURL: URL

        func resolveSnapshot(
            _: ModelSnapshotRequest,
            downloadBase _: URL?,
            progress _: (@Sendable (Progress) -> Void)?
        ) async throws -> URL {
            snapshotURL
        }
    }

    func testResolveCacheDirectory_ExplicitBaseMustBeFileURL() {
        let explicitBase = URL(string: "https://example.com/cache")!

        XCTAssertThrowsError(
            try HuggingFaceHubModelStore.resolveHuggingFaceHubCacheDirectory(
                explicitBase: explicitBase,
                environment: [:],
                homeDirectory: URL(fileURLWithPath: "/Users/tester")
            )
        ) { error in
            guard let storeError = error as? ModelStoreError else {
                XCTFail("Expected ModelStoreError, got \(error)")
                return
            }
            guard case .invalidBaseDirectory = storeError else {
                XCTFail("Expected ModelStoreError.invalidBaseDirectory, got \(error)")
                return
            }
        }
    }

    func testResolveCacheDirectory_HFHubCacheTakesPrecedenceAndExpandsTilde() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let env = [
            "HF_HOME": "  ~/hf  ",
            "HF_HUB_CACHE": "  ~/hub-cache  ",
        ]

        let url = try HuggingFaceHubModelStore.resolveHuggingFaceHubCacheDirectory(
            explicitBase: nil,
            environment: env,
            homeDirectory: home
        )

        XCTAssertEqual(url, URL(fileURLWithPath: "/Users/tester/hub-cache").standardizedFileURL)
    }

    func testResolveCacheDirectory_HFHomeUsedWhenHubCacheMissing() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let env = ["HF_HOME": "  ~/hf  "]

        let url = try HuggingFaceHubModelStore.resolveHuggingFaceHubCacheDirectory(
            explicitBase: nil,
            environment: env,
            homeDirectory: home
        )

        XCTAssertEqual(url, URL(fileURLWithPath: "/Users/tester/hf").appendingPathComponent("hub").standardizedFileURL)
    }

    func testResolveCacheDirectory_DefaultUsesHomeCache() throws {
        let home = URL(fileURLWithPath: "/Users/tester")

        let url = try HuggingFaceHubModelStore.resolveHuggingFaceHubCacheDirectory(
            explicitBase: nil,
            environment: [:],
            homeDirectory: home
        )

        XCTAssertEqual(url, URL(fileURLWithPath: "/Users/tester/.cache/huggingface/hub").standardizedFileURL)
    }

    func testResolveCacheDirectory_IgnoresBlankEnvValues() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let env = [
            "HF_HUB_CACHE": "   ",
            "HF_HOME": "\n\t ",
        ]

        let url = try HuggingFaceHubModelStore.resolveHuggingFaceHubCacheDirectory(
            explicitBase: nil,
            environment: env,
            homeDirectory: home
        )

        XCTAssertEqual(url, URL(fileURLWithPath: "/Users/tester/.cache/huggingface/hub").standardizedFileURL)
    }

    func testResolveCacheDirectory_TildeExpandsToHomeDirectory() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let env = ["HF_HUB_CACHE": "~"]

        let url = try HuggingFaceHubModelStore.resolveHuggingFaceHubCacheDirectory(
            explicitBase: nil,
            environment: env,
            homeDirectory: home
        )

        XCTAssertEqual(url, home.standardizedFileURL)
    }

    func testResolveCachedSnapshot_UsesRefsWhenPresent() throws {
        let hub = FileManager.default.temporaryDirectory.appendingPathComponent("hf_hub_\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: hub) }
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)

        let modelID = "acme/test-model"
        let modelDir = hub.appendingPathComponent("models--acme--test-model", isDirectory: true)

        let snapshotsDir = modelDir.appendingPathComponent("snapshots", isDirectory: true)
        let refsDir = modelDir.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)

        let snapshotA = snapshotsDir.appendingPathComponent("111", isDirectory: true)
        let snapshotB = snapshotsDir.appendingPathComponent("222", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotB, withIntermediateDirectories: true)

        let refMain = refsDir.appendingPathComponent("main")
        try "222\n".data(using: .utf8)!.write(to: refMain)

        let resolved = try HuggingFaceHubModelStore.resolveCachedSnapshot(
            modelID: modelID,
            revision: "main",
            downloadBase: hub
        )

        XCTAssertEqual(resolved, snapshotB.standardizedFileURL)
    }

    func testResolveCachedSnapshot_FallsBackToLatestSnapshotWhenRefMissingOrInvalid() throws {
        let hub = FileManager.default.temporaryDirectory.appendingPathComponent("hf_hub_\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: hub) }
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)

        let modelID = "acme/test-model"
        let modelDir = hub.appendingPathComponent("models--acme--test-model", isDirectory: true)

        let snapshotsDir = modelDir.appendingPathComponent("snapshots", isDirectory: true)
        let refsDir = modelDir.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)

        let snapshotA = snapshotsDir.appendingPathComponent("111", isDirectory: true)
        let snapshotB = snapshotsDir.appendingPathComponent("222", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotB, withIntermediateDirectories: true)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: snapshotA.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10_000)],
            ofItemAtPath: snapshotB.path
        )

        let resolvedWithoutRefs = try HuggingFaceHubModelStore.resolveCachedSnapshot(
            modelID: modelID,
            revision: "main",
            downloadBase: hub
        )
        XCTAssertEqual(resolvedWithoutRefs, snapshotB.standardizedFileURL)

        let refMain = refsDir.appendingPathComponent("main")
        try "missing\n".data(using: .utf8)!.write(to: refMain)

        let resolvedWithInvalidRef = try HuggingFaceHubModelStore.resolveCachedSnapshot(
            modelID: modelID,
            revision: "main",
            downloadBase: hub
        )
        XCTAssertEqual(resolvedWithInvalidRef, snapshotB.standardizedFileURL)
    }

    func testResolveExistingSnapshot_UsesExplicitPathBeforeCache() throws {
        let hub = FileManager.default.temporaryDirectory.appendingPathComponent("hf_hub_\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: hub) }
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)

        let explicitSnapshot = hub.appendingPathComponent("explicit_snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: explicitSnapshot, withIntermediateDirectories: true)

        let cachedSnapshot = try makeCachedSnapshot(
            in: hub,
            modelID: "acme/test-model",
            revision: "main",
            snapshotID: "cached"
        )

        let request = ModelSnapshotRequest(modelID: "acme/test-model", revision: "main", matchingGlobs: ["*.json"])
        let resolved = try HuggingFaceHubModelStore.resolveExistingSnapshot(
            request,
            explicitSnapshotPath: "  \(explicitSnapshot.path)  ",
            downloadBase: hub
        )

        XCTAssertEqual(resolved, explicitSnapshot.standardizedFileURL)
        XCTAssertNotEqual(resolved, cachedSnapshot.standardizedFileURL)
    }

    func testResolveSnapshotPreferringExisting_UsesCachedSnapshotBeforeDownloadStore() async throws {
        let hub = FileManager.default.temporaryDirectory.appendingPathComponent("hf_hub_\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: hub) }
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)

        let cachedSnapshot = try makeCachedSnapshot(
            in: hub,
            modelID: "acme/test-model",
            revision: "main",
            snapshotID: "cached"
        )

        let request = ModelSnapshotRequest(modelID: "acme/test-model", revision: "main", matchingGlobs: ["*.json"])
        let resolved = try await HuggingFaceHubModelStore.resolveSnapshotPreferringExisting(
            request,
            explicitSnapshotPath: " \n ",
            downloadBase: hub,
            downloadStore: FailingModelStore(),
            progress: nil
        )

        XCTAssertEqual(resolved, cachedSnapshot.standardizedFileURL)
    }

    func testResolveSnapshotPreferringExisting_FallsBackToDownloadStoreWhenNoLocalSnapshotExists() async throws {
        let hub = FileManager.default.temporaryDirectory.appendingPathComponent("hf_hub_\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: hub) }
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)

        let downloadedSnapshot = hub.appendingPathComponent("downloaded_snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadedSnapshot, withIntermediateDirectories: true)

        let request = ModelSnapshotRequest(modelID: "acme/test-model", revision: "main", matchingGlobs: ["*.json"])
        let resolved = try await HuggingFaceHubModelStore.resolveSnapshotPreferringExisting(
            request,
            explicitSnapshotPath: nil,
            downloadBase: hub,
            downloadStore: StaticModelStore(snapshotURL: downloadedSnapshot),
            progress: nil
        )

        XCTAssertEqual(resolved, downloadedSnapshot.standardizedFileURL)
    }

    private func makeCachedSnapshot(
        in hub: URL,
        modelID: String,
        revision: String,
        snapshotID: String
    ) throws -> URL {
        let modelDir = hub.appendingPathComponent(
            "models--" + modelID.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
        let snapshotsDir = modelDir.appendingPathComponent("snapshots", isDirectory: true)
        let refsDir = modelDir.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)

        let snapshot = snapshotsDir.appendingPathComponent(snapshotID, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try "\(snapshotID)\n".data(using: .utf8)!.write(to: refsDir.appendingPathComponent(revision))
        return snapshot
    }
}
