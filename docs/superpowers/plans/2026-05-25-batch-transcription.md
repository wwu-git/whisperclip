# Batch Audio Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add folder-based batch STT on the Audio File screen: recursive scan, preserve subpaths, write `.txt` to a user-chosen output folder, show run summary, cooperative cancel—without changing single-file History/clipboard behavior.

**Architecture:** New focused types (`AudioFileEnumerator`, `TranscriptWriter`, `BatchTranscriptionCoordinator`) sit under existing `VoiceToTextFactory` / `LLMFactory`. `FileTranscriptionPipeline` deduplicates STT+LLM logic for single-file and batch. `FileTranscriptionView` gains a batch section; `SettingsStore` persists output-folder bookmark.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit (`NSOpenPanel`), SPM test target `WhisperClipTests`, existing WhisperKit/Parakeet via `VoiceToTextProtocol`.

**Spec:** `docs/superpowers/specs/2026-05-25-batch-transcription-design.md`

---

## File map

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/BatchTranscriptionTypes.swift` | Create | `OutputConflictPolicy`, `BatchTranscriptionOptions`, `BatchSummary`, `BatchRunState`, `BatchFailureItem` |
| `Sources/AudioFileEnumerator.swift` | Create | Recursive audio discovery + shared extension list |
| `Sources/TranscriptWriter.swift` | Create | Output path mapping, conflict resolution, UTF-8 write |
| `Sources/FileTranscriptionPipeline.swift` | Create | Shared STT → optional LLM |
| `Sources/BatchTranscriptionCoordinator.swift` | Create | Serial queue, cancel, progress, summary |
| `Sources/SettingsStore.swift` | Modify | Bookmark + batch UI prefs |
| `Sources/FileTranscriptionView.swift` | Modify | Batch UI, folder pickers, conflict alert, wire coordinator |
| `Tests/AudioFileEnumeratorTests.swift` | Create | Enumerator tests |
| `Tests/TranscriptWriterTests.swift` | Create | Writer tests |
| `Tests/BatchTranscriptionCoordinatorTests.swift` | Create | Coordinator tests with injected transcribe closure |

---

### Task 1: Batch domain types

**Files:**
- Create: `Sources/BatchTranscriptionTypes.swift`

- [ ] **Step 1: Add types file**

```swift
import Foundation

enum OutputConflictPolicy: String, CaseIterable, Identifiable {
    case overwrite
    case skipExisting
    case autoRename

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overwrite: return "Overwrite existing files"
        case .skipExisting: return "Skip existing files"
        case .autoRename: return "Auto-rename (name-2.txt, …)"
        }
    }
}

struct BatchTranscriptionOptions {
    var applyPrompt: Bool = true
    var continueOnError: Bool = true
    var conflictPolicy: OutputConflictPolicy = .overwrite
}

struct BatchFailureItem: Equatable {
    let url: URL
    let error: String
}

struct BatchSummary: Equatable {
    var total: Int
    var succeeded: Int
    var skipped: Int
    var failed: Int
    var cancelledByUser: Bool
    var failedItems: [BatchFailureItem]
    var skippedItems: [URL]
}

enum BatchRunState: Equatable {
    case idle
    case running
    case completed
    case cancelled
    case stoppedOnError
}
```

- [ ] **Step 2: Build**

Run: `cd /Users/yu/Data/dev/project/whisperclip && ./local_build.sh Debug 2>&1 | tail -5`  
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Sources/BatchTranscriptionTypes.swift
git commit -m "feat(batch): add batch transcription domain types"
```

---

### Task 2: AudioFileEnumerator (TDD)

**Files:**
- Create: `Sources/AudioFileEnumerator.swift`
- Create: `Tests/AudioFileEnumeratorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import WhisperClip

final class AudioFileEnumeratorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("enumerator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testEnumerateRecursiveIncludesNestedAudio() throws {
        let sub = tempRoot.appendingPathComponent("week1", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let a = sub.appendingPathComponent("a.mp3")
        let b = tempRoot.appendingPathComponent("b.wav")
        FileManager.default.createFile(atPath: a.path, contents: Data([0x00]))
        FileManager.default.createFile(atPath: b.path, contents: Data([0x00]))

        let files = try AudioFileEnumerator.enumerate(root: tempRoot)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains(a.standardizedFileURL))
        XCTAssertTrue(files.contains(b.standardizedFileURL))
    }

    func testEnumerateIgnoresNonAudio() throws {
        let txt = tempRoot.appendingPathComponent("notes.txt")
        let mp3 = tempRoot.appendingPathComponent("x.mp3")
        FileManager.default.createFile(atPath: txt.path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: mp3.path, contents: Data([0x00]))

        let files = try AudioFileEnumerator.enumerate(root: tempRoot)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.lastPathComponent, "x.mp3")
    }

    func testEnumerateEmptyDirectoryReturnsEmpty() throws {
        let files = try AudioFileEnumerator.enumerate(root: tempRoot)
        XCTAssertTrue(files.isEmpty)
    }

    func testEnumerateSortedByPath() throws {
        let z = tempRoot.appendingPathComponent("z.mp3")
        let a = tempRoot.appendingPathComponent("a.mp3")
        FileManager.default.createFile(atPath: z.path, contents: Data([0x00]))
        FileManager.default.createFile(atPath: a.path, contents: Data([0x00]))

        let files = try AudioFileEnumerator.enumerate(root: tempRoot)
        XCTAssertEqual(files.map(\.lastPathComponent), ["a.mp3", "z.mp3"])
    }
}
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `cd /Users/yu/Data/dev/project/whisperclip && swift test --filter AudioFileEnumeratorTests 2>&1 | tail -15`  
Expected: compile error — `AudioFileEnumerator` not found

- [ ] **Step 3: Implement enumerator**

```swift
import Foundation
import UniformTypeIdentifiers

enum AudioFileEnumerator {
    static let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "flac", "ogg", "aiff", "aac", "caf"
    ]

    static func enumerate(root: URL) throws -> [URL] {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root.standardizedFileURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            results.append(url.standardizedFileURL)
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `swift test --filter AudioFileEnumeratorTests 2>&1 | tail -10`  
Expected: `Executed 4 tests` with 0 failures

- [ ] **Step 5: Commit**

```bash
git add Sources/AudioFileEnumerator.swift Tests/AudioFileEnumeratorTests.swift
git commit -m "feat(batch): add recursive audio file enumerator with tests"
```

---

### Task 3: TranscriptWriter (TDD)

**Files:**
- Create: `Sources/TranscriptWriter.swift`
- Create: `Tests/TranscriptWriterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import WhisperClip

final class TranscriptWriterTests: XCTestCase {
    private var inputRoot: URL!
    private var outputRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-\(UUID().uuidString)", isDirectory: true)
        inputRoot = base.appendingPathComponent("in", isDirectory: true)
        outputRoot = base.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inputRoot.deletingLastPathComponent())
    }

    func testPlannedOutputURLPreservesSubpath() throws {
        let sub = inputRoot.appendingPathComponent("week1", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let audio = sub.appendingPathComponent("a.mp3")
        FileManager.default.createFile(atPath: audio.path, contents: Data([0x00]))

        let planned = TranscriptWriter.plannedOutputURL(
            inputFile: audio,
            inputRoot: inputRoot,
            outputRoot: outputRoot
        )
        XCTAssertEqual(planned.lastPathComponent, "a.txt")
        XCTAssertTrue(planned.path.contains("/out/week1/a.txt") || planned.path.contains("/out/week1/a.txt"))
    }

    func testWriteCreatesFileAndSubdirectories() throws {
        let sub = inputRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let audio = sub.appendingPathComponent("clip.wav")
        FileManager.default.createFile(atPath: audio.path, contents: Data([0x00]))

        let written = try TranscriptWriter.write(
            text: "hello batch",
            inputFile: audio,
            inputRoot: inputRoot,
            outputRoot: outputRoot,
            conflictPolicy: .overwrite
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        let content = try String(contentsOf: written, encoding: .utf8)
        XCTAssertEqual(content, "hello batch")
    }

    func testSkipExistingDoesNotWrite() throws {
        let audio = inputRoot.appendingPathComponent("only.mp3")
        FileManager.default.createFile(atPath: audio.path, contents: Data([0x00]))
        let planned = TranscriptWriter.plannedOutputURL(
            inputFile: audio, inputRoot: inputRoot, outputRoot: outputRoot
        )
        try "old".write(to: planned, atomically: true, encoding: .utf8)

        let result = try TranscriptWriter.write(
            text: "new",
            inputFile: audio,
            inputRoot: inputRoot,
            outputRoot: outputRoot,
            conflictPolicy: .skipExisting
        )
        XCTAssertNil(result)
        XCTAssertEqual(try String(contentsOf: planned, encoding: .utf8), "old")
    }

    func testAutoRenameUsesSuffix() throws {
        let audio = inputRoot.appendingPathComponent("x.mp3")
        FileManager.default.createFile(atPath: audio.path, contents: Data([0x00]))
        let planned = TranscriptWriter.plannedOutputURL(
            inputFile: audio, inputRoot: inputRoot, outputRoot: outputRoot
        )
        try "v1".write(to: planned, atomically: true, encoding: .utf8)

        let written = try TranscriptWriter.write(
            text: "v2",
            inputFile: audio,
            inputRoot: inputRoot,
            outputRoot: outputRoot,
            conflictPolicy: .autoRename
        )
        XCTAssertEqual(written?.lastPathComponent, "x-2.txt")
        XCTAssertEqual(try String(contentsOf: written!, encoding: .utf8), "v2")
    }

    func testHasAnyConflictDetectsExistingOutput() throws {
        let audio = inputRoot.appendingPathComponent("a.flac")
        FileManager.default.createFile(atPath: audio.path, contents: Data([0x00]))
        let planned = TranscriptWriter.plannedOutputURL(
            inputFile: audio, inputRoot: inputRoot, outputRoot: outputRoot
        )
        try "exists".write(to: planned, atomically: true, encoding: .utf8)

        let files = try AudioFileEnumerator.enumerate(root: inputRoot)
        XCTAssertTrue(TranscriptWriter.hasAnyOutputConflict(
            inputFiles: files, inputRoot: inputRoot, outputRoot: outputRoot
        ))
    }
}
```

- [ ] **Step 2: Run tests — expect FAIL**

Run: `swift test --filter TranscriptWriterTests 2>&1 | tail -10`

- [ ] **Step 3: Implement TranscriptWriter**

```swift
import Foundation

enum TranscriptWriter {
    static func plannedOutputURL(inputFile: URL, inputRoot: URL, outputRoot: URL) -> URL {
        let inputRootURL = inputRoot.standardizedFileURL
        let fileURL = inputFile.standardizedFileURL
        let parentPath = fileURL.deletingLastPathComponent().path
        let rootPath = inputRootURL.path
        let relativeDir: String
        if parentPath == rootPath || parentPath.hasPrefix(rootPath + "/") == false {
            if parentPath == rootPath {
                relativeDir = ""
            } else {
                relativeDir = String(parentPath.dropFirst(rootPath.count + 1))
            }
        } else {
            relativeDir = String(parentPath.dropFirst(rootPath.count + 1))
        }
        let stem = fileURL.deletingPathExtension().lastPathComponent
        var url = outputRoot.standardizedFileURL
        if !relativeDir.isEmpty {
            url = url.appendingPathComponent(relativeDir, isDirectory: true)
        }
        return url.appendingPathComponent(stem + ".txt")
    }

    static func hasAnyOutputConflict(
        inputFiles: [URL],
        inputRoot: URL,
        outputRoot: URL
    ) -> Bool {
        inputFiles.contains { file in
            let planned = plannedOutputURL(inputFile: file, inputRoot: inputRoot, outputRoot: outputRoot)
            return FileManager.default.fileExists(atPath: planned.path)
        }
    }

    /// Returns written URL, or nil when skipped (`skipExisting`).
    static func write(
        text: String,
        inputFile: URL,
        inputRoot: URL,
        outputRoot: URL,
        conflictPolicy: OutputConflictPolicy
    ) throws -> URL? {
        var destination = plannedOutputURL(
            inputFile: inputFile, inputRoot: inputRoot, outputRoot: outputRoot
        )
        if conflictPolicy == .skipExisting, FileManager.default.fileExists(atPath: destination.path) {
            return nil
        }
        if conflictPolicy == .autoRename {
            destination = firstAvailableURL(base: destination)
        }
        try GenericHelper.folderCreate(folder: destination.deletingLastPathComponent())
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    private static func firstAvailableURL(base: URL) -> URL {
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        let dir = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(stem)-\(n).txt")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }
}
```

Fix `plannedOutputURL` relative path logic if tests fail: use `fileURL.path.replacingOccurrences(of: rootPath + "/", with: "")` then `dirname` from that.

Simpler implementation for `relativeDir`:

```swift
let relativePath = fileURL.path.replacingOccurrences(of: rootPath + "/", with: "")
let relativeDir = (relativePath as NSString).deletingLastPathComponent
```

Use whichever passes tests.

- [ ] **Step 4: Run tests — expect PASS**

Run: `swift test --filter TranscriptWriterTests 2>&1 | tail -10`

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriptWriter.swift Tests/TranscriptWriterTests.swift
git commit -m "feat(batch): add transcript writer with path and conflict handling"
```

---

### Task 4: FileTranscriptionPipeline (shared STT+LLM)

**Files:**
- Create: `Sources/FileTranscriptionPipeline.swift`
- Modify: `Sources/FileTranscriptionView.swift` (later in Task 7; can do pipeline first)

- [ ] **Step 1: Add pipeline**

```swift
import Foundation

enum FileTranscriptionPipeline {
    @MainActor
    static func transcribe(
        audioURL: URL,
        applyPrompt: Bool,
        settings: SettingsStore = .shared
    ) async throws -> String {
        let voiceToText = VoiceToTextFactory.createVoiceToText()
        let text = try await voiceToText.process(filepath: audioURL.path)

        let prompt = settings.currentPrompt
        guard applyPrompt, !prompt.isEmpty else { return text }

        let llm = LLMFactory.createLLM()
        let isReady = try await llm.isReady()
        guard isReady else {
            throw NSError(
                domain: "FileTranscriptionPipeline",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "LLM is not ready. Please download it from Setup Guide."]
            )
        }
        return try await llm.process(prompt: prompt, text: text)
    }
}
```

- [ ] **Step 2: Build**

Run: `./local_build.sh Debug 2>&1 | tail -5`  
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/FileTranscriptionPipeline.swift
git commit -m "feat(batch): extract shared file transcription pipeline"
```

---

### Task 5: BatchTranscriptionCoordinator (TDD)

**Files:**
- Create: `Sources/BatchTranscriptionCoordinator.swift`
- Create: `Tests/BatchTranscriptionCoordinatorTests.swift`

- [ ] **Step 1: Write failing coordinator tests**

```swift
import XCTest
@testable import WhisperClip

@MainActor
final class BatchTranscriptionCoordinatorTests: XCTestCase {
    private var inputRoot: URL!
    private var outputRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-\(UUID().uuidString)", isDirectory: true)
        inputRoot = base.appendingPathComponent("in", isDirectory: true)
        outputRoot = base.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inputRoot.deletingLastPathComponent())
    }

    func testRunProcessesAllFiles() async throws {
        makeAudio(name: "a.mp3")
        makeAudio(name: "b.mp3")
        let files = try AudioFileEnumerator.enumerate(root: inputRoot)
        let coordinator = BatchTranscriptionCoordinator(
            transcribe: { _ in "ok" }
        )
        let options = BatchTranscriptionOptions(conflictPolicy: .overwrite)
        await coordinator.run(
            inputRoot: inputRoot,
            outputRoot: outputRoot,
            files: files,
            options: options
        )
        XCTAssertEqual(coordinator.state, .completed)
        XCTAssertEqual(coordinator.summary?.succeeded, 2)
        XCTAssertEqual(coordinator.summary?.failed, 0)
    }

    func testContinueOnErrorFalseStopsAfterFailure() async throws {
        makeAudio(name: "a.mp3")
        makeAudio(name: "b.mp3")
        let files = try AudioFileEnumerator.enumerate(root: inputRoot)
        var call = 0
        let coordinator = BatchTranscriptionCoordinator(
            transcribe: { _ in
                call += 1
                if call == 1 { throw NSError(domain: "t", code: 1) }
                return "ok"
            }
        )
        var options = BatchTranscriptionOptions(continueOnError: false, conflictPolicy: .overwrite)
        await coordinator.run(
            inputRoot: inputRoot, outputRoot: outputRoot, files: files, options: options
        )
        XCTAssertEqual(coordinator.state, .stoppedOnError)
        XCTAssertEqual(coordinator.summary?.succeeded, 0)
        XCTAssertEqual(coordinator.summary?.failed, 1)
    }

    func testCancelSkipsRemainingFiles() async throws {
        makeAudio(name: "a.mp3")
        makeAudio(name: "b.mp3")
        let files = try AudioFileEnumerator.enumerate(root: inputRoot)
        let coordinator = BatchTranscriptionCoordinator(
            transcribe: { url in
                if url.lastPathComponent == "a.mp3" {
                    await coordinatorRef.requestCancel()
                }
                return "text"
            }
        )
        var coordinatorRef: BatchTranscriptionCoordinator!
        coordinatorRef = coordinator
        let options = BatchTranscriptionOptions(conflictPolicy: .overwrite)
        await coordinator.run(
            inputRoot: inputRoot, outputRoot: outputRoot, files: files, options: options
        )
        XCTAssertEqual(coordinator.state, .cancelled)
        XCTAssertTrue(coordinator.summary?.cancelledByUser == true)
        // Only first file written
        XCTAssertEqual(coordinator.summary?.succeeded, 1)
    }

    private func makeAudio(name: String) {
        let url = inputRoot.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
    }
}
```

Adjust cancel test: use coordinator that captures self weakly or call `requestCancel()` after first write in simpler test:

```swift
func testCancelBeforeSecondFile() async throws {
    makeAudio(name: "a.mp3")
    makeAudio(name: "b.mp3")
    let files = try AudioFileEnumerator.enumerate(root: inputRoot)
    let coordinator = BatchTranscriptionCoordinator(transcribe: { _ in "x" })
    let options = BatchTranscriptionOptions(conflictPolicy: .overwrite)
    let task = Task { await coordinator.run(...) }
    coordinator.requestCancel()
    await task.value
    XCTAssertEqual(coordinator.state, .cancelled)
}
```

Use the simpler cancel test in implementation.

- [ ] **Step 2: Run tests — expect FAIL**

Run: `swift test --filter BatchTranscriptionCoordinatorTests 2>&1 | tail -10`

- [ ] **Step 3: Implement coordinator**

```swift
import Foundation
import Combine

@MainActor
final class BatchTranscriptionCoordinator: ObservableObject {
    typealias TranscribeHandler = (URL) async throws -> String

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

    convenience init() {
        self.init { url in
            try await FileTranscriptionPipeline.transcribe(
                audioURL: url,
                applyPrompt: SettingsStore.shared.batchApplyPrompt
            )
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

            if isCancelled { break }

            if options.conflictPolicy == .skipExisting {
                let planned = TranscriptWriter.plannedOutputURL(
                    inputFile: file, inputRoot: inputRoot, outputRoot: outputRoot
                )
                if FileManager.default.fileExists(atPath: planned.path) {
                    skipped += 1
                    skippedItems.append(file)
                    continue
                }
            }

            do {
                let text = try await transcribe(file)
                if isCancelled { break }

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

        let finalSummary = BatchSummary(
            total: files.count,
            succeeded: succeeded,
            skipped: skipped,
            failed: failed,
            cancelledByUser: isCancelled,
            failedItems: failedItems,
            skippedItems: skippedItems
        )
        summary = finalSummary

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
```

Fix convenience init to read `applyPrompt` from options at run time, not SettingsStore at init—pass `options.applyPrompt` into pipeline inside `run`:

```swift
self.init()
// default init uses:
transcribe: { url in
  try await FileTranscriptionPipeline.transcribe(audioURL: url, applyPrompt: /* from run */)
}
```

Better: only use injected handler in tests; production `run` calls:

```swift
let text = try await FileTranscriptionPipeline.transcribe(
    audioURL: file, applyPrompt: options.applyPrompt
)
```

Remove broken `convenience init`; use default handler closure created in `run` without separate init.

Default coordinator:

```swift
init(transcribe: TranscribeHandler? = nil) {
  self.transcribe = transcribe ?? { url, applyPrompt in ... }
}
```

Simplest: always require explicit handler in tests; in app `BatchTranscriptionCoordinator()` sets:

```swift
self.transcribe = { url in
  try await FileTranscriptionPipeline.transcribe(audioURL: url, applyPrompt: SettingsStore.shared.batchApplyPrompt)
}
```

And `run` uses `options.applyPrompt` by capturing in closure at start of run—replace handler per run:

```swift
private var transcribeHandler: TranscribeHandler!

func run(...) async {
  transcribeHandler = { try await FileTranscriptionPipeline.transcribe(audioURL: $0, applyPrompt: options.applyPrompt) }
  ...
}
```

Document in plan: store `options.applyPrompt` at beginning of `run` for the transcribe closure.

- [ ] **Step 4: Run tests — expect PASS**

Run: `swift test --filter BatchTranscriptionCoordinatorTests 2>&1 | tail -10`

- [ ] **Step 5: Commit**

```bash
git add Sources/BatchTranscriptionCoordinator.swift Tests/BatchTranscriptionCoordinatorTests.swift
git commit -m "feat(batch): add batch transcription coordinator with cancel and tests"
```

---

### Task 6: SettingsStore bookmark + batch prefs

**Files:**
- Modify: `Sources/SettingsStore.swift`
- Modify: `Sources/DefaultSettings` section in same file

- [ ] **Step 1: Add keys and properties**

In `Keys` enum add:

```swift
case batchOutputDirectoryBookmark = "batchOutputDirectoryBookmark"
case batchApplyPrompt = "batchApplyPrompt"
case batchContinueOnError = "batchContinueOnError"
```

In `DefaultSettings`:

```swift
static let batchApplyPrompt = true
static let batchContinueOnError = true
```

Add published properties with didSet persistence (mirror existing pattern):

```swift
@Published var batchApplyPrompt: Bool = DefaultSettings.batchApplyPrompt { didSet { defaults.set(batchApplyPrompt, forKey: Keys.batchApplyPrompt.rawValue) } }
@Published var batchContinueOnError: Bool = DefaultSettings.batchContinueOnError { didSet { defaults.set(batchContinueOnError, forKey: Keys.batchContinueOnError.rawValue) } }
```

Add methods:

```swift
func saveBatchOutputDirectory(url: URL) {
    if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
        defaults.set(data, forKey: Keys.batchOutputDirectoryBookmark.rawValue)
    }
}

func resolveBatchOutputDirectory() -> URL? {
    guard let data = defaults.data(forKey: Keys.batchOutputDirectoryBookmark.rawValue) else { return nil }
    var stale = false
    return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
}
```

Load in `init()` from defaults for the two Bool prefs.

- [ ] **Step 2: Build**

Run: `./local_build.sh Debug 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Sources/SettingsStore.swift
git commit -m "feat(batch): persist output folder bookmark and batch UI prefs"
```

---

### Task 7: FileTranscriptionView — batch UI + wiring

**Files:**
- Modify: `Sources/FileTranscriptionView.swift`

- [ ] **Step 1: Refactor single-file transcribe to pipeline**

Replace body of `transcribeFile()` Task with:

```swift
let enhancedText = try await FileTranscriptionPipeline.transcribe(
    audioURL: url,
    applyPrompt: !settings.currentPrompt.isEmpty
)
```

(When prompt empty, pass `applyPrompt: false`.)

- [ ] **Step 2: Add state and coordinator**

```swift
@StateObject private var batchCoordinator = BatchTranscriptionCoordinator()
@State private var batchInputRoot: URL?
@State private var batchOutputRoot: URL?
@State private var showConflictSheet = false
@State private var pendingBatchFiles: [URL] = []
@State private var showBatchDetails = false
@State private var selectedConflictPolicy: OutputConflictPolicy = .overwrite
```

On appear, restore output from `settings.resolveBatchOutputDirectory()` into `batchOutputRoot`.

- [ ] **Step 3: Add batch section UI below single-file block**

Insert after supported formats HStack (before single-file Transcribe button) OR after entire single-file `VStack`—prefer **after** single-file block + divider:

Structure:

```swift
Divider().background(Color.white.opacity(0.1)).padding(.vertical, 8)
batchSection
```

`batchSection` contains:
- Title "Batch transcription"
- HStack: label + path truncated + Button "Choose…" for input
- Same for output
- Toggle `batchApplyPrompt` bound to `settings.batchApplyPrompt`
- Toggle `batchContinueOnError` bound to `settings.batchContinueOnError`
- HStack: Start button (disabled if roots nil or batchCoordinator.state == .running)
- Cancel button (visible when running)
- Progress text from coordinator
- Summary text when completed/cancelled/stoppedOnError
- DisclosureGroup for failed/skipped lists

- [ ] **Step 4: Folder picker helper**

```swift
private func selectDirectory(completion: (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        completion(url)
    }
}
```

Output picker calls `settings.saveBatchOutputDirectory(url:)` and sets `batchOutputRoot`.

- [ ] **Step 5: Start batch flow**

```swift
private func startBatch() {
    guard let inputRoot = batchInputRoot, let outputRoot = batchOutputRoot else { return }
    do {
        let files = try AudioFileEnumerator.enumerate(root: inputRoot)
        guard !files.isEmpty else {
            errorMessage = "No supported audio files found in the selected folder."
            return
        }
        if TranscriptWriter.hasAnyOutputConflict(
            inputFiles: files, inputRoot: inputRoot, outputRoot: outputRoot
        ) {
            pendingBatchFiles = files
            showConflictSheet = true
            return
        }
        launchBatch(files: files, inputRoot: inputRoot, outputRoot: outputRoot, policy: .overwrite)
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
    _ = outputRoot.startAccessingSecurityScopedResource()
    Task {
        await batchCoordinator.run(
            inputRoot: inputRoot,
            outputRoot: outputRoot,
            files: files,
            options: options
        )
        outputRoot.stopAccessingSecurityScopedResource()
        await MainActor.run {
            presentBatchSummary()
        }
    }
}
```

- [ ] **Step 6: Conflict confirmation sheet**

```swift
.confirmationDialog(
    "Output files already exist",
    isPresented: $showConflictSheet,
    titleVisibility: .visible
) {
    ForEach(OutputConflictPolicy.allCases) { policy in
        Button(policy.displayName) {
            guard let inRoot = batchInputRoot, let outRoot = batchOutputRoot else { return }
            launchBatch(files: pendingBatchFiles, inputRoot: inRoot, outputRoot: outRoot, policy: policy)
        }
    }
    Button("Cancel", role: .cancel) {}
}
```

- [ ] **Step 7: Present batch summary in result area**

```swift
private func presentBatchSummary() {
    guard let s = batchCoordinator.summary else { return }
    var lines: [String] = []
    if s.cancelledByUser { lines.append("Batch cancelled.") }
    lines.append("Succeeded: \(s.succeeded) · Skipped: \(s.skipped) · Failed: \(s.failed) · Total: \(s.total)")
    if !s.failedItems.isEmpty {
        lines.append("Failures:")
        lines += s.failedItems.map { "• \($0.url.lastPathComponent): \($0.error)" }
    }
    resultText = lines.joined(separator: "\n")
    statusMessage = s.cancelledByUser ? "Batch cancelled" : "Batch finished"
}
```

Do **not** call `TranscriptionHistory.add` or `copyToClipboard` in batch path.

- [ ] **Step 8: Cancel button**

```swift
Button("Cancel batch") {
    batchCoordinator.requestCancel()
}
.disabled(batchCoordinator.state != .running)
```

Show `batchCoordinator.isFinishingCurrentAfterCancel` as caption "Finishing current file…"

- [ ] **Step 9: Build and manual smoke**

Run: `./local_build.sh Debug && ./local_run.sh Debug`  
Manual: pick small folder, output folder, run batch, cancel mid-run, verify `.txt` tree.

- [ ] **Step 10: Commit**

```bash
git add Sources/FileTranscriptionView.swift
git commit -m "feat(batch): add batch transcription UI on Audio File view"
```

---

### Task 8: Full test suite + README note

**Files:**
- Modify: `README.md` (Development section, 3 lines on batch)

- [ ] **Step 1: Run all tests**

Run: `cd /Users/yu/Data/dev/project/whisperclip && swift test 2>&1 | tail -20`  
Expected: all tests pass

- [ ] **Step 2: Add README blurb**

Under Usage / File transcription, add:

```markdown
### Batch folder transcription
On **Audio File**, use **Batch transcription** to select an input folder (recursive) and output folder. Each audio file becomes a `.txt` with the same relative path. Options: apply current prompt, continue on error, conflict policy, cancel.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document batch folder transcription"
```

---

## Spec coverage checklist

| Spec requirement | Task |
|------------------|------|
| Input folder recursive scan | Task 2 |
| Output preserve subpaths | Task 3 |
| Conflict policy dialog | Task 7 Step 6 |
| applyPrompt / continueOnError toggles | Task 6, 7 |
| Cancel cooperative | Task 5, 7 |
| No batch History/clipboard | Task 7 Step 7 |
| Single file unchanged behavior | Task 7 Step 1 |
| Output bookmark persist | Task 6 |
| Serial processing | Task 5 |
| Summary UI | Task 7 Step 7 |
| Empty folder alert | Task 7 Step 5 |

---

## Self-review notes

- `plannedOutputURL` relative path: implement with `path.replacingOccurrences(of: rootPath + "/", with: "")` if nested test fails—fix in Task 3 before proceeding.
- Coordinator `convenience init` removed; `run` builds transcribe closure using `options.applyPrompt`.
- Commit steps optional if user did not request commits; keep for subagent workflow.

---

*Plan complete.*
