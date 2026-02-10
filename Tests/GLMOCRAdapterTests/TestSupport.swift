import Foundation
import XCTest

enum GLMOCRTestEnv {
    static var modelFolderURL: URL? {
        guard let value = ProcessInfo.processInfo.environment["GLMOCR_TEST_MODEL_FOLDER"], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
    }

    static var runGolden: Bool {
        ProcessInfo.processInfo.environment["GLMOCR_RUN_GOLDEN"] == "1"
    }

    static var runForwardPass: Bool {
        ProcessInfo.processInfo.environment["GLMOCR_TEST_RUN_FORWARD_PASS"] == "1" || runGolden
    }

    static var runGenerate: Bool {
        ProcessInfo.processInfo.environment["GLMOCR_TEST_RUN_GENERATE"] == "1"
    }

    static func goldenFixtureData(
        name: String = "glmocr_forward_golden_v1",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw XCTSkip(
                "Golden fixture '\(name).json' not found in test bundle. " +
                    "Generate it via scripts/generate_glmocr_golden.py and place it under Tests/GLMOCRAdapterTests/Fixtures/.",
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

    // Expected layout for SwiftPM:
    //   <bin>/GLMOCRSwiftPackageTests.xctest/Contents/MacOS/GLMOCRSwiftPackageTests
    // and scripts/build_mlx_metallib.sh writes:
    //   <bin>/mlx.metallib
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
