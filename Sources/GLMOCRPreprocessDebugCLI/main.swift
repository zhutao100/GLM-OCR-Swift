import ArgumentParser
import DocLayoutAdapter
import Foundation
import GLMOCRAdapter
import VLMRuntimeKit

enum DebugResizeBackendArg: String, ExpressibleByArgument {
    case both
    case coreimage
    case deterministic
}

private struct ArtifactManifest: Codable {
    var generatedAtUTC: String
    var input: String
    var page: Int
    var glmModel: String
    var glmRevision: String
    var layoutModel: String
    var layoutRevision: String
    var visionInputDType: String
    var normalizationStats: NormalizationStatsManifest?
    var backends: [String]
    var regions: [RegionArtifactManifest]
}

private struct NormalizationStatsManifest: Codable {
    var mean: [Float]
    var std: [Float]
}

private struct RegionArtifactManifest: Codable {
    var regionIndex: Int
    var nativeLabel: String
    var kind: String
    var taskType: String
    var bbox: [Int]
    var cropPixelSize: [Int]
    var backends: [BackendArtifactManifest]
}

private struct BackendArtifactManifest: Codable {
    var name: String
    var targetSize: [Int]
    var artifactPNG: String
    var elapsedMilliseconds: Double
    var tensorSummary: GLMOCRImageTensorSummary
}

struct GLMOCRPreprocessDebugCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "GLMOCRPreprocessDebugCLI",
        abstract: "Dump GLM-OCR preprocess artifacts for layout regions on selected examples."
    )

    @Option(help: "Input image or PDF path.")
    var input: String

    @Option(help: "1-based PDF page index (ignored for images).")
    var page: Int = 1

    @Option(help: "Output directory for artifact manifests and resized RGB PNGs.")
    var outputDir: String

    @Option(name: .customLong("model"), help: "GLM-OCR Hugging Face model id.")
    var model: String = GLMOCRDefaults.modelID

    @Option(help: "GLM-OCR Hugging Face revision.")
    var revision: String = GLMOCRDefaults.revision

    @Option(name: .customLong("layout-model"), help: "Layout model id.")
    var layoutModel: String = PPDocLayoutV3Defaults.modelID

    @Option(name: .customLong("layout-revision"), help: "Layout model revision.")
    var layoutRevision: String = PPDocLayoutV3Defaults.revision

    @Option(help: "Optional download base override.")
    var downloadBase: String?

    @Option(help: "Resize backend to dump: both | coreimage | deterministic")
    var backend: DebugResizeBackendArg = .both

    @Option(name: .customLong("region-index"), help: "Repeatable region index filter.")
    var regionIndex: [Int] = []

    @Option(name: .customLong("region-label"), help: "Repeatable native-label filter.")
    var regionLabel: [String] = []

    mutating func validate() throws {
        guard page >= 1 else {
            throw ValidationError("--page must be >= 1")
        }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--input must be non-empty")
        }
        guard !outputDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--output-dir must be non-empty")
        }
    }

    mutating func run() async throws {
        let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath).standardizedFileURL
        let downloadBaseURL = downloadBase.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let environment = ProcessInfo.processInfo.environment
        let store = HuggingFaceHubModelStore()
        let glmFolder = try await store.resolveSnapshotPreferringExisting(
            ModelSnapshotRequest(modelID: model, revision: revision, matchingGlobs: GLMOCRDefaults.downloadGlobs),
            explicitSnapshotPath: environment["GLMOCR_SNAPSHOT_PATH"],
            downloadBase: downloadBaseURL
        )
        let config = try GLMOCRConfig.load(from: glmFolder)
        let normalizationStats = try GLMOCRPreprocessorConfigLoader.loadNormalizationStats(from: glmFolder)
        let glmModel = try await GLMOCRModel.load(from: glmFolder)

        let detector = PPDocLayoutV3Detector(
            modelID: layoutModel,
            revision: layoutRevision,
            downloadGlobs: PPDocLayoutV3Defaults.downloadGlobs,
            downloadBase: downloadBaseURL
        )
        try await detector.ensureLoaded(progress: nil)

        let pageImage =
            if inputURL.pathExtension.lowercased() == "pdf" {
                try VisionIO.loadCIImage(fromPDF: inputURL, page: page, dpi: 200)
            } else {
                try VisionIO.loadCIImage(from: inputURL)
            }
        let detectedRegions = try await detector.detect(ciImage: SendableCIImage(pageImage))
        let selectedRegions = selectRegions(from: detectedRegions)

        let normalizationManifest = normalizationStats.map {
            NormalizationStatsManifest(
                mean: [$0.mean.0, $0.mean.1, $0.mean.2],
                std: [$0.std.0, $0.std.1, $0.std.2]
            )
        }
        let backendNames = backendList().map(\.manifestName)

        var regionManifests: [RegionArtifactManifest] = []
        regionManifests.reserveCapacity(selectedRegions.count)

        for region in selectedRegions {
            let taskType = PPDocLayoutV3Mappings.labelTaskMapping[region.nativeLabel] ?? .abandon
            let crop = try VisionIO.cropRegion(
                image: pageImage,
                bbox: region.bbox,
                polygon: taskType == .table ? region.polygon : nil,
                fillColor: .white
            )
            let cropWidth = max(Int(crop.extent.width.rounded(.down)), 1)
            let cropHeight = max(Int(crop.extent.height.rounded(.down)), 1)

            var backendArtifacts: [BackendArtifactManifest] = []
            backendArtifacts.reserveCapacity(backendNames.count)

            for resizeBackend in backendList() {
                var options = GLMOCRImageProcessingOptions()
                options.alignDTypeToVisionWeights = true
                options.dtype = glmModel.visionInputDType
                options.resizeBackend = resizeBackend
                if let normalizationStats {
                    options.mean = normalizationStats.mean
                    options.std = normalizationStats.std
                }

                let processor = GLMOCRImageProcessor(options: options)
                let started = ContinuousClock.now
                let inspection = try processor.inspect(crop, config: config)
                let elapsed = started.duration(to: ContinuousClock.now)

                let fileName = artifactFileName(region: region, backend: resizeBackend)
                let artifactURL = outputURL.appendingPathComponent(fileName)
                try VisionIO.writePNG(inspection.resizedRGB, to: artifactURL)

                backendArtifacts.append(
                    BackendArtifactManifest(
                        name: resizeBackend.manifestName,
                        targetSize: [inspection.targetWidth, inspection.targetHeight],
                        artifactPNG: fileName,
                        elapsedMilliseconds: elapsed.seconds * 1_000,
                        tensorSummary: inspection.tensorSummary
                    )
                )
            }

            regionManifests.append(
                RegionArtifactManifest(
                    regionIndex: region.index,
                    nativeLabel: region.nativeLabel,
                    kind: region.kind.rawValue,
                    taskType: taskType.rawValue,
                    bbox: [region.bbox.x1, region.bbox.y1, region.bbox.x2, region.bbox.y2],
                    cropPixelSize: [cropWidth, cropHeight],
                    backends: backendArtifacts
                )
            )
        }

        let manifest = ArtifactManifest(
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            input: inputURL.path,
            page: page,
            glmModel: model,
            glmRevision: revision,
            layoutModel: layoutModel,
            layoutRevision: layoutRevision,
            visionInputDType: String(describing: glmModel.visionInputDType),
            normalizationStats: normalizationManifest,
            backends: backendNames,
            regions: regionManifests
        )

        let manifestURL = outputURL.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL)

        FileHandle.standardOutput.write(Data("Wrote preprocess artifacts to \(outputURL.path)\n".utf8))
        FileHandle.standardOutput.write(Data("Manifest: \(manifestURL.path)\n".utf8))
    }

    private func backendList() -> [GLMOCRResizeBackend] {
        switch backend {
        case .both:
            [.coreImageBicubic, .deterministicBicubicCPU]
        case .coreimage:
            [.coreImageBicubic]
        case .deterministic:
            [.deterministicBicubicCPU]
        }
    }

    private func selectRegions(from regions: [OCRRegion]) -> [OCRRegion] {
        let allowedIndices = Set(regionIndex)
        let allowedLabels = Set(regionLabel)

        return regions.filter { region in
            let taskType = PPDocLayoutV3Mappings.labelTaskMapping[region.nativeLabel] ?? .abandon
            guard taskType != .skip, taskType != .abandon else { return false }
            let indexMatches = allowedIndices.isEmpty || allowedIndices.contains(region.index)
            let labelMatches = allowedLabels.isEmpty || allowedLabels.contains(region.nativeLabel)
            return indexMatches && labelMatches
        }
    }

    private func artifactFileName(region: OCRRegion, backend: GLMOCRResizeBackend) -> String {
        let label = sanitize(region.nativeLabel)
        return String(format: "region_%03d_%@_%@.png", region.index, label, backend.manifestName)
    }

    private func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars)
    }
}

extension GLMOCRResizeBackend {
    fileprivate var manifestName: String {
        switch self {
        case .coreImageBicubic:
            "coreimage"
        case .deterministicBicubicCPU:
            "deterministic"
        }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

GLMOCRPreprocessDebugCLI.main()
