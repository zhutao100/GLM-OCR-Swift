import Foundation
import XCTest

enum GLMOCRTestEnv {
    static var modelFolderURL: URL? {
        guard let value = ProcessInfo.processInfo.environment["GLMOCR_TEST_MODEL_FOLDER"], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
    }

    static var runForwardPass: Bool {
        ProcessInfo.processInfo.environment["GLMOCR_TEST_RUN_FORWARD_PASS"] == "1"
    }

    static var runGenerate: Bool {
        ProcessInfo.processInfo.environment["GLMOCR_TEST_RUN_GENERATE"] == "1"
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
