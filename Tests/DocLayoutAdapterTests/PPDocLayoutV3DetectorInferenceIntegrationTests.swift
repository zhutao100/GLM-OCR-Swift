import CoreImage
import DocLayoutAdapter
import VLMRuntimeKit
import XCTest

final class PPDocLayoutV3DetectorInferenceIntegrationTests: XCTestCase {
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

    func testDetect_emitsValidRegionsWhenSnapshotPathProvided() async throws {
        guard let raw = ProcessInfo.processInfo.environment["LAYOUT_SNAPSHOT_PATH"], !raw.isEmpty else {
            throw XCTSkip("Set LAYOUT_SNAPSHOT_PATH to a local PP-DocLayout-V3 HF snapshot folder to enable this test.")
        }

        let folder = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        let detector = PPDocLayoutV3Detector(store: StaticModelStore(snapshotFolder: folder))

        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(
            to: CGRect(x: 0, y: 0, width: 800, height: 800))
        let regions = try await detector.detect(ciImage: image)

        XCTAssertFalse(regions.isEmpty)

        for region in regions {
            XCTAssertTrue((0...1000).contains(region.bbox.x1))
            XCTAssertTrue((0...1000).contains(region.bbox.y1))
            XCTAssertTrue((0...1000).contains(region.bbox.x2))
            XCTAssertTrue((0...1000).contains(region.bbox.y2))
            XCTAssertLessThan(region.bbox.x1, region.bbox.x2)
            XCTAssertLessThan(region.bbox.y1, region.bbox.y2)
        }
    }
}
