import DocLayoutAdapter
import VLMRuntimeKit
import XCTest

final class PPDocLayoutV3DetectorLoadOnlyIntegrationTests: XCTestCase {
    private struct StaticModelStore: ModelStore {
        var snapshotFolder: URL

        func resolveSnapshot(
            _: ModelSnapshotRequest,
            downloadBase _: URL?,
            progress _: (@Sendable (Progress) -> Void)?
        ) async throws -> URL {
            snapshotFolder
        }
    }

    func testEnsureLoaded_validatesRequiredKeysWhenSnapshotPathProvided() async throws {
        guard let raw = ProcessInfo.processInfo.environment["LAYOUT_SNAPSHOT_PATH"], !raw.isEmpty else {
            throw XCTSkip("Set LAYOUT_SNAPSHOT_PATH to a local PP-DocLayout-V3 HF snapshot folder to enable this test.")
        }

        let folder = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        let detector = PPDocLayoutV3Detector(store: StaticModelStore(snapshotFolder: folder))

        try await detector.ensureLoaded()

        let loadedFolder = await detector.snapshotFolder()
        let loadedConfig = await detector.loadedConfig()

        XCTAssertNotNil(loadedFolder)
        XCTAssertNotNil(loadedConfig)
    }
}
