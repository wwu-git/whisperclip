import Foundation
import Combine

@MainActor
final class BatchTranscriptionCoordinator: ObservableObject {
    typealias TranscribeHandler = (URL, Bool) async throws -> String

    @Published private(set) var state: BatchRunState = .idle
    @Published private(set) var progress: (current: Int, total: Int) = (0, 0)
    @Published private(set) var currentFileName: String?
    @Published private(set) var summary: BatchSummary?
    @Published private(set) var isFinishingCurrentAfterCancel = false

    private var isCancelled = false
    private let transcribe: TranscribeHandler

    init(transcribe: @escaping TranscribeHandler) {
        self.transcribe = transcribe
    }

    init() {
        self.transcribe = { url, applyPrompt in
            try await FileTranscriptionPipeline.transcribe(audioURL: url, applyPrompt: applyPrompt)
        }
    }

    func requestCancel() {
        guard state == .running else { return }
        isCancelled = true
        isFinishingCurrentAfterCancel = true
    }

    func run(
        inputRoot: URL,
        outputRoot: URL,
        files: [URL],
        options: BatchTranscriptionOptions
    ) async {
        state = .running
        isCancelled = false
        isFinishingCurrentAfterCancel = false
        summary = nil
        progress = (0, files.count)

        var succeeded = 0
        var skipped = 0
        var failed = 0
        var failedItems: [BatchFailureItem] = []
        var skippedItems: [URL] = []
        var stoppedOnError = false

        for (index, file) in files.enumerated() {
            progress = (index, files.count)
            currentFileName = file.lastPathComponent

            if isCancelled {
                break
            }

            if options.conflictPolicy == .skipExisting {
                let planned = TranscriptWriter.plannedOutputURL(
                    inputFile: file,
                    inputRoot: inputRoot,
                    outputRoot: outputRoot
                )
                if FileManager.default.fileExists(atPath: planned.path) {
                    skipped += 1
                    skippedItems.append(file)
                    continue
                }
            }

            do {
                let text = try await transcribe(file, options.applyPrompt)
                if isCancelled {
                    break
                }

                let written = try TranscriptWriter.write(
                    text: text,
                    inputFile: file,
                    inputRoot: inputRoot,
                    outputRoot: outputRoot,
                    conflictPolicy: options.conflictPolicy
                )
                if written == nil {
                    skipped += 1
                    skippedItems.append(file)
                } else {
                    succeeded += 1
                }
            } catch {
                failed += 1
                failedItems.append(BatchFailureItem(url: file, error: error.localizedDescription))
                if !options.continueOnError {
                    stoppedOnError = true
                    break
                }
            }
        }

        progress = (files.count, files.count)
        currentFileName = nil
        isFinishingCurrentAfterCancel = false

        summary = BatchSummary(
            total: files.count,
            succeeded: succeeded,
            skipped: skipped,
            failed: failed,
            cancelledByUser: isCancelled,
            failedItems: failedItems,
            skippedItems: skippedItems
        )

        if isCancelled {
            state = .cancelled
        } else if stoppedOnError {
            state = .stoppedOnError
        } else {
            state = .completed
        }
    }

    func resetToIdle() {
        state = .idle
        summary = nil
        progress = (0, 0)
        currentFileName = nil
        isCancelled = false
        isFinishingCurrentAfterCancel = false
    }
}
