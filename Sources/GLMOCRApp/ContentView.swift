import GLMOCRAdapter
import SwiftUI
import UniformTypeIdentifiers
import VLMRuntimeKit

@MainActor
final class AppViewModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloading(String)
        case ready
        case running(String)
        case error(String)
    }

    @Published var status: Status = .idle
    @Published var droppedFile: URL?
    @Published var task: OCRTask = .text
    @Published var output: String = ""
    @Published var maxNewTokens: Int = 2048

    private let pipeline = GLMOCRPipeline()

    func downloadModelIfNeeded() {
        Task {
            do {
                status = .downloading("Starting download...")
                try await pipeline.ensureLoaded { progress in
                    let completed = progress.completedUnitCount
                    let total = max(progress.totalUnitCount, 1)
                    Task { @MainActor in
                        self.status = .downloading("Downloading model files: \(completed)/\(total)")
                    }
                }
                status = .ready
            } catch {
                status = .error("Model download/load failed: \(error)")
            }
        }
    }

    func runOCR() {
        guard let url = droppedFile else {
            status = .error("Drop an image or PDF first.")
            return
        }

        Task {
            do {
                status = .running("Running OCR...")
                let options = GenerateOptions(maxNewTokens: maxNewTokens, temperature: 0, topP: 1)
                let result = try await pipeline.recognize(.file(url, page: 1), task: task, options: options)
                output = result.text
                status = .ready
            } catch {
                status = .error(String(describing: error))
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        VStack(spacing: 12) {
            header
            controls
            dropZone
            outputView
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            Text("GLM-OCR (Swift) — Starter")
                .font(.title2)
                .bold()

            Spacer()

            Group {
                switch vm.status {
                case .idle:
                    Text("Idle")
                case let .downloading(s):
                    Text(s)
                case .ready:
                    Text("Ready")
                case let .running(s):
                    Text(s)
                case let .error(e):
                    Text("Error: \(e)")
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Task", selection: $vm.task) {
                Text("Text").tag(OCRTask.text)
                Text("Formula").tag(OCRTask.formula)
                Text("Table").tag(OCRTask.table)
                Text("JSON").tag(OCRTask.structuredJSON(schema: "{\n  \"type\": \"object\"\n}"))
            }
            .pickerStyle(.segmented)

            Stepper("Max tokens: \(vm.maxNewTokens)", value: $vm.maxNewTokens, in: 128 ... 8192, step: 128)
                .frame(width: 250)

            Spacer()

            Button("Download/Load Model") { vm.downloadModelIfNeeded() }
            Button("Run") { vm.runOCR() }
                .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text(vm.droppedFile?.lastPathComponent ?? "Drag & drop an image/PDF here")
                    .font(.headline)
                Text("Supported: common images + PDF (uses page 1 for PDFs)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(height: 120)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    vm.droppedFile = url
                }
            }
            return true
        }
    }

    private var outputView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.headline)
            TextEditor(text: $vm.output)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 260)
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.tertiary, lineWidth: 1)
                }
        }
    }
}
