import ArgumentParser
import CoreImage
import Darwin
import Dispatch
import DocLayoutAdapter
import Foundation
import GLMOCRAdapter
import MLX
import VLMRuntimeKit

actor DownloadProgressPrinter {
    private let modelID: String
    private var lastCompleted: Int64 = -1

    init(modelID: String) {
        self.modelID = modelID
    }

    func update(completed: Int64, total: Int64) {
        guard completed != lastCompleted else { return }
        lastCompleted = completed

        let total = max(total, 1)
        FileHandle.standardError.write(Data("Downloading \(modelID) (\(completed)/\(total) files)\n".utf8))
    }
}

final class SIGINTCanceller {
    private let source: DispatchSourceSignal
    private let onCancel: @Sendable () -> Void
    private var hitCount: Int = 0

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel

        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))

        source.setEventHandler { [weak self] in
            guard let self else { return }
            hitCount += 1
            if hitCount == 1 {
                FileHandle.standardError.write(Data("SIGINT received; cancelling…\n".utf8))
                self.onCancel()
            } else {
                FileHandle.standardError.write(Data("SIGINT received again; exiting.\n".utf8))
                exit(130)
            }
        }

        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

enum TaskPreset: String, ExpressibleByArgument {
    case text
    case formula
    case table
    case json
}

enum LayoutParallelismArg: String, ExpressibleByArgument {
    case auto
    case one = "1"
    case two = "2"
}

@main
struct GLMOCRCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "GLMOCRCLI",
        abstract: "GLM-OCR native Swift starter (MLX Swift + HF tooling)."
    )

    @Option(help: "Hugging Face model id to download/use.")
    var model: String = GLMOCRDefaults.modelID

    @Option(help: "Hugging Face revision (branch/tag/commit).")
    var revision: String = GLMOCRDefaults.revision

    @Option(help: "Hub download base directory (defaults to Hugging Face hub cache).")
    var downloadBase: String?

    @Option(help: "Input image or PDF file path.")
    var input: String?

    @Option(help: "PDF page (1-based). Only used when --input is a PDF.")
    var page: Int = 1

    @Flag(name: .customLong("layout"), help: "Enable layout mode (default: on for PDFs, off otherwise).")
    var layout: Bool = false

    @Flag(name: .customLong("no-layout"), help: "Disable layout mode.")
    var noLayout: Bool = false

    @Option(help: "Layout OCR parallelism: auto | 1 | 2")
    var layoutParallelism: LayoutParallelismArg = .auto

    @Option(help: "Write canonical block-list JSON (examples-compatible) to path (layout mode only).")
    var emitJson: String?

    @Option(name: .customLong("emit-ocrdocument-json"), help: "Write structured OCRDocument JSON to path (layout mode only).")
    var emitOCRDocumentJson: String?

    @Option(help: "Task preset: text | formula | table | json")
    var task: TaskPreset = .text

    @Option(help: "Max new tokens.")
    var maxNewTokens: Int = 2048

    @Flag(help: "Do not run inference; just resolve/download the model snapshot.")
    var downloadOnly: Bool = false

    @Flag(help: "Developer: load the model and run a single forward pass (synthetic inputs).")
    var devForwardPass: Bool = false

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedFileURL(fromPath path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    private static func resolveLayoutEnabled(inputURL: URL?, layout: Bool, noLayout: Bool) -> Bool {
        let explicit: Bool? = layout ? true : (noLayout ? false : nil)
        if let explicit { return explicit }
        let isPDF = inputURL?.pathExtension.lowercased() == "pdf"
        return isPDF
    }

    mutating func validate() throws {
        guard maxNewTokens > 0 else {
            throw ValidationError("--max-new-tokens must be > 0")
        }
        guard page > 0 else {
            throw ValidationError("--page must be >= 1")
        }

        if layout, noLayout {
            throw ValidationError("Pass at most one of --layout or --no-layout")
        }

        if emitJson != nil, Self.normalizedNonEmpty(emitJson) == nil {
            throw ValidationError("--emit-json path must be non-empty")
        }
        if emitOCRDocumentJson != nil, Self.normalizedNonEmpty(emitOCRDocumentJson) == nil {
            throw ValidationError("--emit-ocrdocument-json path must be non-empty")
        }

        if downloadOnly || devForwardPass {
            if emitJson != nil || emitOCRDocumentJson != nil {
                throw ValidationError("--emit-json/--emit-ocrdocument-json require running inference")
            }
            return
        }
        guard let inputPath = Self.normalizedNonEmpty(input) else {
            throw ValidationError("--input is required unless --download-only or --dev-forward-pass is set")
        }

        let url = Self.normalizedFileURL(fromPath: inputPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ValidationError("Input not found: \(url.path)")
        }
        if isDirectory.boolValue {
            throw ValidationError("Input is a directory: \(url.path)")
        }

        if emitJson != nil || emitOCRDocumentJson != nil {
            let layoutEnabled = Self.resolveLayoutEnabled(inputURL: url, layout: layout, noLayout: noLayout)
            guard layoutEnabled else {
                throw ValidationError("--emit-json/--emit-ocrdocument-json require layout mode (pass --layout for non-PDF inputs)")
            }
        }
    }

    mutating func run() async throws {
        let modelID = model
        let modelRevision = revision
        let maxNewTokens = maxNewTokens
        let page = page
        let downloadOnly = downloadOnly
        let devForwardPass = devForwardPass
        let downloadBaseURL: URL? = Self.normalizedNonEmpty(downloadBase).map(Self.normalizedFileURL(fromPath:))

        let inputURL: URL? = Self.normalizedNonEmpty(input).map(Self.normalizedFileURL(fromPath:))
        let layoutEnabled = Self.resolveLayoutEnabled(inputURL: inputURL, layout: layout, noLayout: noLayout)
        let emitJsonURL: URL? = Self.normalizedNonEmpty(emitJson).map(Self.normalizedFileURL(fromPath:))
        let emitOCRDocumentJsonURL: URL? = Self.normalizedNonEmpty(emitOCRDocumentJson).map(Self.normalizedFileURL(fromPath:))

        let taskPreset: OCRTask = switch task {
        case .text: .text
        case .formula: .formula
        case .table: .table
        case .json: .structuredJSON(schema: "{\n  \"type\": \"object\"\n}")
        }

        let generateOptions = GenerateOptions(maxNewTokens: maxNewTokens, temperature: 0, topP: 1)

        let concurrencyPolicy: LayoutConcurrencyPolicy = switch layoutParallelism {
        case .auto: .auto
        case .one: .fixed(1)
        case .two: .fixed(2)
        }
        let layoutOptions = GLMOCRLayoutOptions(concurrency: concurrencyPolicy, maxConcurrentRegionsCap: 2)

        let workTask = Task {
            try await Self.runWork(
                modelID: modelID,
                revision: modelRevision,
                downloadBaseURL: downloadBaseURL,
                inputURL: inputURL,
                page: page,
                taskPreset: taskPreset,
                generateOptions: generateOptions,
                downloadOnly: downloadOnly,
                devForwardPass: devForwardPass,
                layoutEnabled: layoutEnabled,
                layoutOptions: layoutOptions,
                emitJsonURL: emitJsonURL,
                emitOCRDocumentJsonURL: emitOCRDocumentJsonURL
            )
        }

        let sigint = SIGINTCanceller {
            workTask.cancel()
        }
        defer { sigint.cancel() }

        do {
            try await workTask.value
        } catch is CancellationError {
            throw ExitCode(130)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func runWork(
        modelID: String,
        revision: String,
        downloadBaseURL: URL?,
        inputURL: URL?,
        page: Int,
        taskPreset: OCRTask,
        generateOptions: GenerateOptions,
        downloadOnly: Bool,
        devForwardPass: Bool,
        layoutEnabled: Bool,
        layoutOptions: GLMOCRLayoutOptions,
        emitJsonURL: URL?,
        emitOCRDocumentJsonURL: URL?
    ) async throws {
        let store: any ModelStore = HuggingFaceHubModelStore()

        let glmPrinter = DownloadProgressPrinter(modelID: modelID)
        let glmRequest = ModelSnapshotRequest(modelID: modelID, revision: revision, matchingGlobs: GLMOCRDefaults.downloadGlobs)
        let glmFolder = try await store.resolveSnapshot(glmRequest, downloadBase: downloadBaseURL) { progress in
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { await glmPrinter.update(completed: completed, total: total) }
        }

        if layoutEnabled {
            let layoutModelID = PPDocLayoutV3Defaults.modelID
            let layoutPrinter = DownloadProgressPrinter(modelID: layoutModelID)
            let layoutRequest = ModelSnapshotRequest(
                modelID: layoutModelID,
                revision: PPDocLayoutV3Defaults.revision,
                matchingGlobs: PPDocLayoutV3Defaults.downloadGlobs
            )
            _ = try await store.resolveSnapshot(layoutRequest, downloadBase: downloadBaseURL) { progress in
                let completed = progress.completedUnitCount
                let total = progress.totalUnitCount
                Task { await layoutPrinter.update(completed: completed, total: total) }
            }
        }

        if downloadOnly { return }

        if devForwardPass {
            try await runDevForwardPass(modelFolder: glmFolder)
            return
        }

        guard let inputURL else {
            throw ValidationError("--input is required unless --download-only or --dev-forward-pass is set")
        }

        if layoutEnabled {
            if taskPreset != .text {
                FileHandle.standardError.write(Data("Note: --task is ignored in layout mode.\n".utf8))
            }

            let pipeline = GLMOCRLayoutPipeline(
                modelID: modelID,
                revision: revision,
                downloadBase: downloadBaseURL,
                layoutOptions: layoutOptions
            )
            try await pipeline.ensureLoaded(progress: nil)
            let result = try await pipeline.recognize(.file(inputURL, page: page), task: taskPreset, options: generateOptions)
            var markdown = result.text

            if let emitJsonURL {
                guard let document = result.document else { throw ValidationError("Layout pipeline did not produce a document.") }
                try writeBlockListJSON(document, to: emitJsonURL)
            }

            if let emitOCRDocumentJsonURL {
                guard let document = result.document else { throw ValidationError("Layout pipeline did not produce a document.") }
                try writeOCRDocumentJSON(document, to: emitOCRDocumentJsonURL)
            }

            if let baseOutputDir = (emitJsonURL ?? emitOCRDocumentJsonURL)?.deletingLastPathComponent() {
                do {
                    let pageIndex = inputURL.pathExtension.lowercased() == "pdf" ? max(page - 1, 0) : 0

                    let pageImage: CIImage = if inputURL.pathExtension.lowercased() == "pdf" {
                        try VisionIO.loadCIImage(fromPDF: inputURL, page: page, dpi: 200)
                    } else {
                        try VisionIO.loadCIImage(from: inputURL)
                    }

                    let placeholder = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
                    var pageImages = Array(repeating: placeholder, count: pageIndex + 1)
                    pageImages[pageIndex] = pageImage

                    let imgsDir = baseOutputDir.appendingPathComponent("imgs")
                    markdown = try MarkdownImageCropper.cropAndReplaceImages(
                        markdown: markdown,
                        pageImages: pageImages,
                        outputDir: imgsDir,
                        imagePrefix: "cropped"
                    ).markdown
                } catch {
                    FileHandle.standardError.write(Data("Warning: failed to crop/replace image refs: \(error)\n".utf8))
                }
            }

            print(markdown)
            return
        }

        if emitJsonURL != nil || emitOCRDocumentJsonURL != nil {
            throw ValidationError("--emit-json/--emit-ocrdocument-json require layout mode (pass --layout for non-PDF inputs)")
        }

        let pipeline = GLMOCRPipeline(modelID: modelID, revision: revision, downloadBase: downloadBaseURL)
        try await pipeline.ensureLoaded(progress: nil)

        let result = try await pipeline.recognize(.file(inputURL, page: page), task: taskPreset, options: generateOptions)
        print(result.text)
    }

    private static func writeBlockListJSON(_ document: OCRDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(document.toBlockListExport())
        try data.write(to: url, options: .atomic)
    }

    private static func writeOCRDocumentJSON(_ document: OCRDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    private static func runDevForwardPass(modelFolder: URL) async throws {
        let config = try GLMOCRConfig.load(from: modelFolder)
        let tokenizer = try await GLMOCRTokenizer.load(from: modelFolder, config: config)
        let ids = tokenizer.specialTokenIDs

        let imageSize = config.visionConfig.imageSize ?? 336
        let patchSize = config.visionConfig.patchSize ?? 14
        let temporalPatchSize = config.visionConfig.temporalPatchSize ?? 2
        let mergeSize = config.visionConfig.spatialMergeSize ?? 2

        let grid = imageSize / patchSize
        let downGrid = grid / mergeSize
        let numImageTokens = downGrid * downGrid // depth collapses to 1 when D == temporalPatchSize

        MLXRandom.seed(0)
        let pixelValues = MLXRandom.normal([1, temporalPatchSize, imageSize, imageSize, 3]).asType(.bfloat16)

        let promptTokenIDs = tokenizer.tokenizer.encode(text: " OCR:", addSpecialTokens: false)
        var inputIds: [Int] = [ids.gMaskId, ids.sopId, ids.userId, ids.beginImageId]
        inputIds.append(contentsOf: Array(repeating: ids.imageId, count: numImageTokens))
        inputIds.append(ids.endImageId)
        inputIds.append(contentsOf: promptTokenIDs)

        let inputIdArray = MLXArray(inputIds.map { Int32($0) }).reshaped(1, -1)

        let model = try await GLMOCRModel.load(from: modelFolder)
        let logits = try model.forward(inputIds: inputIdArray, pixelValues: pixelValues)
        try checkedEval(logits)

        let shape = logits.shape
        FileHandle.standardError.write(Data("Logits shape: \(shape)\n".utf8))

        let last = logits[0, -1].asType(.float32).asArray(Float.self)
        let topK = 5
        let pairs = last.enumerated().sorted(by: { $0.element > $1.element }).prefix(topK)
        for (id, value) in pairs {
            FileHandle.standardError.write(Data("top\(topK): id=\(id) logit=\(value)\n".utf8))
        }
    }
}
