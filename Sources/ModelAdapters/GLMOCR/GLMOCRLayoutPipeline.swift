import CoreImage
import DocLayoutAdapter
import Foundation
import VLMRuntimeKit

public enum LayoutConcurrencyPolicy: Sendable, Equatable {
    case auto
    case fixed(Int)
}

public struct GLMOCRLayoutOptions: Sendable, Equatable {
    public var concurrency: LayoutConcurrencyPolicy
    /// Hard safety cap for concurrent region OCR.
    public var maxConcurrentRegionsCap: Int

    public init(concurrency: LayoutConcurrencyPolicy = .auto, maxConcurrentRegionsCap: Int = 2) {
        self.concurrency = concurrency
        self.maxConcurrentRegionsCap = maxConcurrentRegionsCap
    }

    public func resolvedMaxConcurrentRegions(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let auto: Int = physicalMemory < 24 * 1024 * 1024 * 1024 ? 1 : 2

        let base: Int =
            switch concurrency {
            case .auto:
                auto
            case .fixed(let value):
                value
            }

        let cap = max(1, maxConcurrentRegionsCap)
        return min(max(1, base), cap)
    }
}

public enum GLMOCRLayoutPipelineError: Error, Sendable, Equatable {
    case invalidInputURL(URL)
    case inputNotFound(URL)
    case inputIsDirectory(URL)
    case invalidPDFPageIndex(Int)
    case expectedPDF(URL)
    case unsupportedInput
    case missingDocument
    case unexpectedDocumentPageCount(Int)
    case unexpectedAbandonRegion(label: String)
}

/// Orchestrates: page → layout regions → crop → per-region GLM-OCR → merged Markdown + `OCRDocument`.
public actor GLMOCRLayoutPipeline: OCRPipeline {
    public typealias Input = GLMOCRInput

    private let modelID: String
    private let revision: String

    private let ocrPipeline: GLMOCRPipeline
    private let layoutDetector: PPDocLayoutV3Detector
    private let layoutOptions: GLMOCRLayoutOptions
    private let pdfDPI: Int

    public init(
        modelID: String = GLMOCRDefaults.modelID,
        revision: String = GLMOCRDefaults.revision,
        downloadGlobs: [String] = GLMOCRDefaults.downloadGlobs,
        layoutModelID: String = PPDocLayoutV3Defaults.modelID,
        layoutRevision: String = PPDocLayoutV3Defaults.revision,
        layoutDownloadGlobs: [String] = PPDocLayoutV3Defaults.downloadGlobs,
        downloadBase: URL? = nil,
        store: any ModelStore = HuggingFaceHubModelStore(),
        processor: GLMOCRProcessor = .init(),
        layoutOptions: GLMOCRLayoutOptions = .init(),
        pdfDPI: Int = 200
    ) {
        self.modelID = modelID
        self.revision = revision
        ocrPipeline = GLMOCRPipeline(
            modelID: modelID,
            revision: revision,
            downloadGlobs: downloadGlobs,
            downloadBase: downloadBase,
            store: store,
            processor: processor
        )
        layoutDetector = PPDocLayoutV3Detector(
            modelID: layoutModelID,
            revision: layoutRevision,
            downloadGlobs: layoutDownloadGlobs,
            downloadBase: downloadBase,
            store: store
        )
        self.layoutOptions = layoutOptions
        self.pdfDPI = pdfDPI
    }

    public func ensureLoaded(progress: (@Sendable (Progress) -> Void)? = nil) async throws {
        async let loadOCR: Void = ocrPipeline.ensureLoaded(progress: progress)
        async let loadLayout: Void = layoutDetector.ensureLoaded(progress: progress)
        _ = try await (loadOCR, loadLayout)
    }

    public func recognizePDF(url: URL, pagesSpec: PDFPagesSpec = .all, options: GenerateOptions) async throws
        -> OCRResult
    {
        guard url.pathExtension.lowercased() == "pdf" else {
            throw GLMOCRLayoutPipelineError.expectedPDF(url)
        }

        try await ensureLoaded(progress: nil)

        let pageCount = try VisionIO.pdfPageCount(url: url)
        let pages = try pagesSpec.resolve(pageCount: pageCount)

        var pageMarkdowns: [String] = []
        pageMarkdowns.reserveCapacity(pages.count)

        var collectedPages: [OCRPage] = []
        collectedPages.reserveCapacity(pages.count)

        for page in pages {
            try Task.checkCancellation()

            let result = try await recognize(.file(url, page: page), task: .text, options: options)
            pageMarkdowns.append(result.text)

            guard let document = result.document else {
                throw GLMOCRLayoutPipelineError.missingDocument
            }
            guard document.pages.count == 1, let only = document.pages.first else {
                throw GLMOCRLayoutPipelineError.unexpectedDocumentPageCount(document.pages.count)
            }
            collectedPages.append(only)
        }

        let mergedPages = collectedPages.sorted(by: { $0.index < $1.index })
        let mergedDocument = OCRDocument(pages: mergedPages)
        let markdown = pageMarkdowns.joined(separator: "\n\n")

        return OCRResult(
            text: markdown,
            rawTokens: nil,
            document: mergedDocument,
            diagnostics: .init(modelID: modelID, revision: revision)
        )
    }

    public func recognize(_ input: GLMOCRInput, task: OCRTask, options: GenerateOptions) async throws -> OCRResult {
        _ = task  // task is determined per-region in layout mode.

        let (url, page) = try validateFileInput(input)

        try await ensureLoaded(progress: nil)

        let layoutImage: CIImage =
            if url.pathExtension.lowercased() == "pdf" {
                try VisionIO.loadCIImage(fromPDF: url, page: page, dpi: CGFloat(pdfDPI))
            } else {
                try VisionIO.loadCIImage(from: url)
            }

        try Task.checkCancellation()
        let detected = try await layoutDetector.detect(ciImage: layoutImage)

        try Task.checkCancellation()
        let cropImage: CIImage =
            if url.pathExtension.lowercased() == "pdf" {
                try VisionIO.loadCIImage(fromPDF: url, page: page, dpi: CGFloat(pdfDPI))
            } else {
                try VisionIO.loadCIImage(from: url)
            }

        let resolvedConcurrency = layoutOptions.resolvedMaxConcurrentRegions()
        var regions = detected

        let sendablePageImage = SendableCIImage(cropImage)
        let regionOCR = ocrPipeline

        var workItems: [WorkItem] = []
        workItems.reserveCapacity(regions.count)
        for (offset, region) in regions.enumerated() {
            let taskType = PPDocLayoutV3Mappings.labelTaskMapping[region.nativeLabel] ?? .abandon
            switch taskType {
            case .skip:
                continue
            case .abandon:
                throw GLMOCRLayoutPipelineError.unexpectedAbandonRegion(label: region.nativeLabel)
            case .text, .table, .formula:
                workItems.append(WorkItem(offset: offset, region: region, taskType: taskType))
            }
        }

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            var inFlight = 0

            func scheduleNext() throws {
                guard next < workItems.count else { return }
                try Task.checkCancellation()

                let item = workItems[next]
                next += 1
                inFlight += 1

                group.addTask { [sendablePageImage] in
                    try Task.checkCancellation()

                    let cropped = try VisionIO.cropRegion(
                        image: sendablePageImage.value,
                        bbox: item.region.bbox,
                        polygon: item.region.polygon,
                        fillColor: .white
                    )

                    let mappedTask: OCRTask =
                        switch item.taskType {
                        case .text: .text
                        case .table: .table
                        case .formula: .formula
                        case .skip, .abandon: .text
                        }

                    let result = try await regionOCR.recognize(ciImage: cropped, task: mappedTask, options: options)
                    return (item.offset, result.text)
                }
            }

            do {
                while inFlight < resolvedConcurrency, next < workItems.count {
                    try scheduleNext()
                }

                while let (offset, content) = try await group.next() {
                    inFlight -= 1
                    regions[offset].content = content

                    while inFlight < resolvedConcurrency, next < workItems.count {
                        try scheduleNext()
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }

        let pageIndex = url.pathExtension.lowercased() == "pdf" ? (page - 1) : 0
        let (document, markdown) = LayoutResultFormatter.format(pages: [OCRPage(index: pageIndex, regions: regions)])

        return OCRResult(
            text: markdown, rawTokens: nil, document: document, diagnostics: .init(modelID: modelID, revision: revision)
        )
    }

    private func validateFileInput(_ input: GLMOCRInput) throws -> (url: URL, page: Int) {
        let url: URL
        let page: Int
        switch input {
        case .file(let u, let p):
            url = u
            page = p
        case .predecodedText:
            throw GLMOCRLayoutPipelineError.unsupportedInput
        }

        guard url.isFileURL else { throw GLMOCRLayoutPipelineError.invalidInputURL(url) }
        guard page >= 1 else { throw GLMOCRLayoutPipelineError.invalidPDFPageIndex(page) }

        let normalizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory) else {
            throw GLMOCRLayoutPipelineError.inputNotFound(normalizedURL)
        }
        if isDirectory.boolValue {
            throw GLMOCRLayoutPipelineError.inputIsDirectory(normalizedURL)
        }

        return (normalizedURL, page)
    }
}

private struct WorkItem: Sendable, Equatable {
    let offset: Int
    let region: OCRRegion
    let taskType: LayoutTaskType
}
