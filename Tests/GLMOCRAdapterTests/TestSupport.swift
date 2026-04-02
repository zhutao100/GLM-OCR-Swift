import Foundation
import GLMOCRAdapter
import VLMRuntimeKit
import XCTest

private struct SwiftPMPreparationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class SwiftPMTestSupport: @unchecked Sendable {
    static let shared = SwiftPMTestSupport()

    let projectRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private let lock = NSLock()
    private var preparedConfigurations: Set<String> = []

    func ensureMLXMetalLibraryPrepared(configuration: String) throws {
        lock.lock()
        defer { lock.unlock() }

        if preparedConfigurations.contains(configuration) {
            return
        }

        try runProcess(
            executable: "/bin/bash",
            arguments: [
                projectRoot.appendingPathComponent("scripts/build_mlx_metallib.sh").path,
                "--configuration",
                configuration,
            ]
        )
        preparedConfigurations.insert(configuration)
    }

    static func configuration(for executableURL: URL?) -> String {
        guard let path = executableURL?.path.lowercased() else {
            return "debug"
        }
        return path.contains("/release/") ? "release" : "debug"
    }

    private func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output =
                String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let error =
                String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let combined = [output, error].filter { !$0.isEmpty }.joined(separator: "\n")
            throw SwiftPMPreparationError(
                message:
                    "Failed to prepare SwiftPM MLX artifacts with `\(executable) \(arguments.joined(separator: " "))`"
                    + (combined.isEmpty ? "" : "\n\(combined)")
            )
        }
    }
}

enum GLMOCRTestEnv {
    static var modelFolderURL: URL? {
        if let value = ProcessInfo.processInfo.environment["GLMOCR_SNAPSHOT_PATH"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        }

        return try? HuggingFaceHubModelStore.resolveCachedSnapshot(
            modelID: GLMOCRDefaults.modelID,
            revision: GLMOCRDefaults.revision,
            downloadBase: nil
        )
    }

    static func requireModelFolderURL(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        guard let url = modelFolderURL else {
            throw XCTSkip(
                "No cached HF snapshot found for \(GLMOCRDefaults.modelID) (\(GLMOCRDefaults.revision)). "
                    + "Either download it to your HF cache or set GLMOCR_SNAPSHOT_PATH to a local snapshot folder.",
                file: file,
                line: line
            )
        }
        return url
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
                "Golden fixture '\(name).json' not found in test bundle. "
                    + "Generate it via scripts/python/generate_glmocr_golden.py and place it under Tests/GLMOCRAdapterTests/Fixtures/.",
                file: file,
                line: line
            )
        }
        return try Data(contentsOf: url)
    }
}

class MLXTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try ensureMLXMetalLibraryColocated(for: type(of: self))
    }
}

func ensureMLXMetalLibraryColocated(for testCase: AnyClass) throws {
    guard let executableURL = Bundle(for: testCase).executableURL else {
        throw XCTSkip("Cannot determine test executable location for colocating mlx.metallib.")
    }

    let configuration = SwiftPMTestSupport.configuration(for: executableURL)
    let binaryDir = executableURL.deletingLastPathComponent()
    let colocated = binaryDir.appendingPathComponent("mlx.metallib")
    if FileManager.default.fileExists(atPath: colocated.path) { return }

    // Expected layout for SwiftPM:
    //   <bin>/GLMOCRSwiftPackageTests.xctest/Contents/MacOS/GLMOCRSwiftPackageTests
    // and scripts/build_mlx_metallib.sh writes:
    //   <bin>/mlx.metallib
    let binRoot =
        binaryDir
        .deletingLastPathComponent()  // Contents
        .deletingLastPathComponent()  // *.xctest
        .deletingLastPathComponent()  // <bin>
    let built = binRoot.appendingPathComponent("mlx.metallib")
    if !FileManager.default.fileExists(atPath: built.path) {
        try SwiftPMTestSupport.shared.ensureMLXMetalLibraryPrepared(configuration: configuration)
    }

    guard FileManager.default.fileExists(atPath: built.path) else {
        throw SwiftPMPreparationError(
            message: "mlx.metallib was not produced at \(built.path) for SwiftPM \(configuration) tests."
        )
    }

    _ = try? FileManager.default.removeItem(at: colocated)
    try FileManager.default.copyItem(at: built, to: colocated)
}

func makeWorkspaceTempDir(prefix: String) throws -> URL {
    let root = SwiftPMTestSupport.shared.projectRoot
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("test-tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let dir = root.appendingPathComponent("\(prefix)_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
