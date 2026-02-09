@testable import VLMRuntimeKit
import XCTest

final class ModelStoreTests: XCTestCase {
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
}
