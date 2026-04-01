import CoreGraphics
import CoreImage
import DocLayoutAdapter
import Foundation
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

enum DocLayoutTestEnv {
    static var snapshotFolderURL: URL? {
        if let value = ProcessInfo.processInfo.environment["LAYOUT_SNAPSHOT_PATH"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        }

        return try? HuggingFaceHubModelStore.resolveCachedSnapshot(
            modelID: PPDocLayoutV3Defaults.modelID,
            revision: PPDocLayoutV3Defaults.revision,
            downloadBase: nil
        )
    }

    static func requireSnapshotFolderURL(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        guard let url = snapshotFolderURL else {
            throw XCTSkip(
                "No cached HF snapshot found for \(PPDocLayoutV3Defaults.modelID) (\(PPDocLayoutV3Defaults.revision)). "
                    + "Either download it to your HF cache or set LAYOUT_SNAPSHOT_PATH to a local snapshot folder.",
                file: file,
                line: line
            )
        }
        return url
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
                "Golden fixture '\(name).json' not found in test bundle. "
                    + "Generate it via scripts/python/generate_ppdoclayoutv3_golden.py and place it under Tests/DocLayoutAdapterTests/Fixtures/.",
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

private enum DeterministicImageError: Error, Sendable {
    case cgImageCreationFailed
}

func makeDeterministicCIImage(imageSize: Int) throws -> CIImage {
    let width = max(imageSize, 1)
    let height = max(imageSize, 1)
    let wDenom = max(width - 1, 1)
    let hDenom = max(height - 1, 1)
    let bDenom = max((width - 1) + (height - 1), 1)

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        let g = (y * 255) / hDenom
        for x in 0..<width {
            let r = (x * 255) / wDenom
            let b = ((x + y) * 255) / bDenom
            let idx = (y * width + x) * 4
            pixels[idx + 0] = UInt8(r)
            pixels[idx + 1] = UInt8(g)
            pixels[idx + 2] = UInt8(b)
            pixels[idx + 3] = 255
        }
    }

    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData) else {
        throw DeterministicImageError.cgImageCreationFailed
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )

    guard
        let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    else {
        throw DeterministicImageError.cgImageCreationFailed
    }

    return CIImage(cgImage: cg)
}
