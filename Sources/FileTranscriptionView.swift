import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FileTranscriptionView: View {
    @State private var selectedFileURL: URL?
    @State private var resultText: String = ""
    @State private var isProcessing: Bool = false
    @State private var statusMessage: String = ""
    @State private var errorMessage: String = ""
    @State private var showShareSheet: Bool = false
    @State private var isDragging: Bool = false
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var batchCoordinator = BatchTranscriptionCoordinator()

    @State private var batchInputRoot: URL?
    @State private var batchOutputRoot: URL?
    @State private var showConflictDialog = false
    @State private var pendingBatchFiles: [URL] = []
    @State private var showBatchDetails = false

    private let supportedTypes: [UTType] = [
        .audio,
        .mp3,
        .wav,
        .aiff,
        UTType(filenameExtension: "m4a") ?? .audio,
        UTType(filenameExtension: "flac") ?? .audio,
        UTType(filenameExtension: "ogg") ?? .audio,
        .mpeg4Audio
    ]

    private var isBatchRunning: Bool {
        batchCoordinator.state == .running
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.1),
                    Color(red: 0.03, green: 0.06, blue: 0.12),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    singleFileSection
                    Divider().background(Color.white.opacity(0.15))
                    batchSection

                    if !resultText.isEmpty || !errorMessage.isEmpty {
                        VStack(spacing: 0) {
                            Divider()
                                .background(Color.white.opacity(0.1))

                            if !resultText.isEmpty {
                                ResultView(
                                    resultText: resultText,
                                    statusMessage: statusMessage,
                                    showShareSheet: $showShareSheet
                                )
                                .padding(20)
                            }

                            if !errorMessage.isEmpty {
                                ErrorView(errorMessage: errorMessage)
                                    .padding(20)
                            }
                        }
                        .background(Color.black.opacity(0.3))
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
            }
        }
        .foregroundColor(.white)
        .onAppear {
            if batchOutputRoot == nil {
                batchOutputRoot = settings.resolveBatchOutputDirectory()
            }
        }
        .confirmationDialog(
            "Output files already exist",
            isPresented: $showConflictDialog,
            titleVisibility: .visible
        ) {
            ForEach(OutputConflictPolicy.allCases) { policy in
                Button(policy.displayName) {
                    guard let inputRoot = batchInputRoot,
                          let outputRoot = batchOutputRoot else { return }
                    launchBatch(
                        files: pendingBatchFiles,
                        inputRoot: inputRoot,
                        outputRoot: outputRoot,
                        policy: policy
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Single file

    private var singleFileSection: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        RadialGradient(
                            colors: [Color.blue.opacity(isDragging ? 0.3 : 0.1), Color.clear],
                            center: .center,
                            startRadius: 50,
                            endRadius: 150
                        )
                    )
                    .frame(width: 280, height: 200)
                    .blur(radius: 30)

                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        isDragging ? Color.blue : Color.white.opacity(0.2),
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
                    .frame(width: 260, height: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white.opacity(isDragging ? 0.08 : 0.03))
                    )

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 70, height: 70)

                        Image(systemName: selectedFileURL != nil ? "doc.fill" : "arrow.down.doc.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.blue)
                    }

                    if let url = selectedFileURL {
                        VStack(spacing: 4) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Button {
                                selectedFileURL = nil
                                resultText = ""
                                statusMessage = ""
                                errorMessage = ""
                            } label: {
                                Text("Remove")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        VStack(spacing: 4) {
                            Text("Drop audio file here")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)

                            Text("or click to browse")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .onTapGesture {
                if !isProcessing && !isBatchRunning {
                    selectFile()
                }
            }
            .onDrop(of: [.audio, .fileURL], isTargeted: $isDragging) { providers in
                handleDrop(providers: providers)
            }

            HStack(spacing: 8) {
                ForEach(["MP3", "WAV", "M4A", "FLAC"], id: \.self) { format in
                    Text(format)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(4)
                }
            }

            if selectedFileURL != nil {
                Button {
                    transcribeFile()
                } label: {
                    HStack(spacing: 12) {
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                                .tint(.white)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 16))
                        }
                        Text(isProcessing ? "Transcribing..." : "Transcribe")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.blue, .blue.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                    )
                    .shadow(color: .blue.opacity(0.4), radius: 10, y: 5)
                }
                .buttonStyle(.plain)
                .disabled(isProcessing || isBatchRunning)
            }
        }
    }

    // MARK: - Batch

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Batch transcription")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            folderRow(
                label: "Input folder",
                url: batchInputRoot,
                action: { selectInputFolder() }
            )

            folderRow(
                label: "Output folder",
                url: batchOutputRoot,
                action: { selectOutputFolder() }
            )

            Toggle("Apply current prompt", isOn: $settings.batchApplyPrompt)
                .toggleStyle(.checkbox)
                .disabled(isBatchRunning)

            Toggle("Continue on error", isOn: $settings.batchContinueOnError)
                .toggleStyle(.checkbox)
                .disabled(isBatchRunning)

            HStack(spacing: 12) {
                Button {
                    startBatch()
                } label: {
                    Text("Start batch")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(.plain)
                .disabled(batchInputRoot == nil || batchOutputRoot == nil || isBatchRunning || isProcessing)

                if isBatchRunning {
                    Button {
                        batchCoordinator.requestCancel()
                    } label: {
                        Text("Cancel batch")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.red.opacity(0.8)))
                    }
                    .buttonStyle(.plain)
                }
            }

            if isBatchRunning {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Progress: \(batchCoordinator.progress.current) / \(batchCoordinator.progress.total)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    if let name = batchCoordinator.currentFileName {
                        Text("Current: \(name)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    if batchCoordinator.isFinishingCurrentAfterCancel {
                        Text("Finishing current file…")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            if let summary = batchCoordinator.summary, batchCoordinator.state != .running {
                batchSummaryView(summary)
            }
        }
        .frame(maxWidth: 420)
    }

    private func folderRow(label: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.gray)
                Text(url?.path ?? "Not selected")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: action)
                .buttonStyle(.bordered)
                .disabled(isBatchRunning)
        }
    }

    @ViewBuilder
    private func batchSummaryView(_ summary: BatchSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(batchStatusLine(summary))
                .font(.caption)
                .foregroundColor(.green)

            if !summary.failedItems.isEmpty || !summary.skippedItems.isEmpty {
                DisclosureGroup("Details", isExpanded: $showBatchDetails) {
                    if !summary.failedItems.isEmpty {
                        Text("Failed:")
                            .font(.caption)
                            .foregroundColor(.red)
                        ForEach(summary.failedItems, id: \.url) { item in
                            Text("• \(item.url.lastPathComponent): \(item.error)")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                    if !summary.skippedItems.isEmpty {
                        Text("Skipped:")
                            .font(.caption)
                            .foregroundColor(.orange)
                        ForEach(summary.skippedItems, id: \.self) { url in
                            Text("• \(url.lastPathComponent)")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .foregroundColor(.white)
            }
        }
    }

    private func batchStatusLine(_ summary: BatchSummary) -> String {
        var parts = [
            "Succeeded: \(summary.succeeded)",
            "Skipped: \(summary.skipped)",
            "Failed: \(summary.failed)",
            "Total: \(summary.total)"
        ]
        if summary.cancelledByUser {
            parts.insert("Cancelled", at: 0)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.canLoadObject(ofClass: URL.self) {
            provider.loadObject(ofClass: URL.self) { item, error in
                guard let url = item as? URL else { return }
                DispatchQueue.main.async { setSelectedFile(url) }
            }
            return true
        }

        let fileURLType = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, error in
                guard let url = urlFromDropItem(item) else { return }
                DispatchQueue.main.async { setSelectedFile(url) }
            }
            return true
        }
        return false
    }

    private func urlFromDropItem(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let path = item as? String { return URL(fileURLWithPath: path) }
        return nil
    }

    private func setSelectedFile(_ url: URL) {
        selectedFileURL = url
        resultText = ""
        statusMessage = ""
        errorMessage = ""
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = supportedTypes

        if panel.runModal() == .OK, let url = panel.url {
            setSelectedFile(url)
        }
    }

    private func selectInputFolder() {
        selectDirectory { batchInputRoot = $0 }
    }

    private func selectOutputFolder() {
        selectDirectory { url in
            batchOutputRoot = url
            settings.saveBatchOutputDirectory(url: url)
        }
    }

    private func selectDirectory(completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func transcribeFile() {
        guard let url = selectedFileURL else { return }

        isProcessing = true
        errorMessage = ""
        resultText = ""
        statusMessage = ""

        Task {
            do {
                let applyPrompt = !settings.currentPrompt.isEmpty
                let enhancedText = try await FileTranscriptionPipeline.transcribe(
                    audioURL: url,
                    applyPrompt: applyPrompt
                )

                await MainActor.run {
                    resultText = enhancedText
                    GenericHelper.copyToClipboard(text: enhancedText)
                    statusMessage = "✓ Copied to clipboard"
                    isProcessing = false
                    TranscriptionHistory.shared.add(
                        text: enhancedText,
                        source: .file,
                        filename: url.lastPathComponent
                    )
                }
            } catch {
                await MainActor.run {
                    Logger.log("File transcription error: \(error)", log: Logger.audio, type: .error)
                    errorMessage = "Transcription failed: \(error.localizedDescription)"
                    isProcessing = false
                }
            }
        }
    }

    private func startBatch() {
        guard let inputRoot = batchInputRoot, let outputRoot = batchOutputRoot else { return }

        do {
            let files = try AudioFileEnumerator.enumerate(root: inputRoot)
            guard !files.isEmpty else {
                errorMessage = "No supported audio files found in the selected folder."
                return
            }

            if TranscriptWriter.hasAnyOutputConflict(
                inputFiles: files,
                inputRoot: inputRoot,
                outputRoot: outputRoot
            ) {
                pendingBatchFiles = files
                showConflictDialog = true
                return
            }

            launchBatch(
                files: files,
                inputRoot: inputRoot,
                outputRoot: outputRoot,
                policy: .overwrite
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func launchBatch(
        files: [URL],
        inputRoot: URL,
        outputRoot: URL,
        policy: OutputConflictPolicy
    ) {
        errorMessage = ""
        resultText = ""
        statusMessage = ""

        let options = BatchTranscriptionOptions(
            applyPrompt: settings.batchApplyPrompt,
            continueOnError: settings.batchContinueOnError,
            conflictPolicy: policy
        )

        let accessing = outputRoot.startAccessingSecurityScopedResource()
        Task {
            await batchCoordinator.run(
                inputRoot: inputRoot,
                outputRoot: outputRoot,
                files: files,
                options: options
            )
            if accessing {
                outputRoot.stopAccessingSecurityScopedResource()
            }
            await MainActor.run {
                presentBatchSummary()
            }
        }
    }

    private func presentBatchSummary() {
        guard let summary = batchCoordinator.summary else { return }

        var lines: [String] = []
        if summary.cancelledByUser {
            lines.append("Batch cancelled.")
        }
        lines.append(batchStatusLine(summary))

        if !summary.failedItems.isEmpty {
            lines.append("Failures:")
            lines += summary.failedItems.map { "• \($0.url.lastPathComponent): \($0.error)" }
        }
        if !summary.skippedItems.isEmpty {
            lines.append("Skipped:")
            lines += summary.skippedItems.map { "• \($0.lastPathComponent)" }
        }

        resultText = lines.joined(separator: "\n")
        statusMessage = summary.cancelledByUser ? "Batch cancelled" : "Batch finished"
    }
}
