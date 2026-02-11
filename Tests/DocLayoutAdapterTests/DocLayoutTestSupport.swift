import Foundation
import XCTest

enum DocLayoutTestEnv {
    static var snapshotFolderURL: URL? {
        guard let value = ProcessInfo.processInfo.environment["LAYOUT_SNAPSHOT_PATH"], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
    }

    static var runGolden: Bool {
        ProcessInfo.processInfo.environment["LAYOUT_RUN_GOLDEN"] == "1"
    }

    static func goldenFixtureData(
        name: String = "ppdoclayoutv3_forward_golden_v1",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw XCTSkip(
                "Golden fixture '\(name).json' not found in test bundle. " +
                    "Generate it via scripts/generate_ppdoclayoutv3_golden.py and place it under Tests/DocLayoutAdapterTests/Fixtures/.",
                file: file,
                line: line
            )
        }
        return try Data(contentsOf: url)
    }
}

func ensureMLXMetalLibraryColocated(for testCase: AnyClass) throws {
    guard let executableURL = Bundle(for: testCase).executableURL else {
        throw XCTSkip("Cannot determine test executable location for colocating mlx.metallib.")
    }

    let binaryDir = executableURL.deletingLastPathComponent()
    let colocated = binaryDir.appendingPathComponent("mlx.metallib")
    if FileManager.default.fileExists(atPath: colocated.path) { return }

    let binRoot = binaryDir
        .deletingLastPathComponent() // Contents
        .deletingLastPathComponent() // *.xctest
        .deletingLastPathComponent() // <bin>
    let built = binRoot.appendingPathComponent("mlx.metallib")
    guard FileManager.default.fileExists(atPath: built.path) else {
        throw XCTSkip("mlx.metallib not found at \(built.path). Run scripts/build_mlx_metallib.sh first.")
    }

    _ = try? FileManager.default.removeItem(at: colocated)
    try FileManager.default.copyItem(at: built, to: colocated)
}
