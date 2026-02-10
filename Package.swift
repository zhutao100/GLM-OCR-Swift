// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GLMOCRSwift",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "VLMRuntimeKit", targets: ["VLMRuntimeKit"]),
        .library(name: "GLMOCRAdapter", targets: ["GLMOCRAdapter"]),
        .executable(name: "GLMOCRApp", targets: ["GLMOCRApp"]),
        .executable(name: "GLMOCRCLI", targets: ["GLMOCRCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.30.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.1.6")),
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "1.5.0")),
    ],
    targets: [
        .target(
            name: "VLMRuntimeKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("PDFKit"),
            ]
        ),
        .target(
            name: "GLMOCRAdapter",
            dependencies: [
                "VLMRuntimeKit",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/ModelAdapters/GLMOCR",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "GLMOCRApp",
            dependencies: [
                "GLMOCRAdapter",
                "VLMRuntimeKit",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "GLMOCRCLI",
            dependencies: [
                "GLMOCRAdapter",
                "VLMRuntimeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "VLMRuntimeKitTests",
            dependencies: [
                "VLMRuntimeKit",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "GLMOCRAdapterTests",
            dependencies: [
                "GLMOCRAdapter",
            ],
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
