import CoreGraphics
import CoreImage
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
                "Golden fixture '\(name).json' not found in test bundle. "
                    + "Generate it via scripts/generate_ppdoclayoutv3_golden.py and place it under Tests/DocLayoutAdapterTests/Fixtures/.",
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

    let binRoot =
        binaryDir
        .deletingLastPathComponent()  // Contents
        .deletingLastPathComponent()  // *.xctest
        .deletingLastPathComponent()  // <bin>
    let built = binRoot.appendingPathComponent("mlx.metallib")
    guard FileManager.default.fileExists(atPath: built.path) else {
        throw XCTSkip("mlx.metallib not found at \(built.path). Run scripts/build_mlx_metallib.sh first.")
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
