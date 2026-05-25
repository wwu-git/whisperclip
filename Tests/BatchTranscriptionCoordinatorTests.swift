import XCTest
@testable import WhisperClip

@MainActor
final class BatchTranscriptionCoordinatorTests: XCTestCase {
    private var base: URL!
    private var inputRoot: URL!
    private var outputRoot: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-\(UUID().uuidString)", isDirectory: true)
        inputRoot = base.appendingPathComponent("in", isDirectory: true)
        outputRoot = base.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testRunProcessesAllFiles() async throws {
        makeAudio(name: "a.mp3")
        makeAudio(name: "b.mp3")
        let files = try AudioFileEnumerator.enumerate(root: inputRoot)
        let coordinator = BatchTranscriptionCoordinator { _, _ in "ok" }
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
        let coordinator = BatchTranscriptionCoordinator { _, _ in
            call += 1
            if call == 1 {
                throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "fail"])
            }
            return "ok"
        }
        let options = BatchTranscriptionOptions(continueOnError: false, conflictPolicy: .overwrite)
        await coordinator.run(
            inputRoot: inputRoot,
            outputRoot: outputRoot,
            files: files,
            options: options
        )
        XCTAssertEqual(coordinator.state, .stoppedOnError)
        XCTAssertEqual(coordinator.summary?.failed, 1)
        XCTAssertEqual(coordinator.summary?.succeeded, 0)
    }

    func testCancelSkipsRemainingFiles() async throws {
        makeAudio(name: "a.mp3")
        makeAudio(name: "b.mp3")
        let files = try AudioFileEnumerator.enumerate(root: inputRoot)
        var coordinator: BatchTranscriptionCoordinator!
        coordinator = BatchTranscriptionCoordinator { url, _ in
            if url.lastPathComponent == "b.mp3" {
                coordinator.requestCancel()
            }
            return "text"
        }
        let options = BatchTranscriptionOptions(conflictPolicy: .overwrite)
        await coordinator.run(
            inputRoot: inputRoot,
            outputRoot: outputRoot,
            files: files,
            options: options
        )
        XCTAssertEqual(coordinator.state, .cancelled)
        XCTAssertEqual(coordinator.summary?.cancelledByUser, true)
        XCTAssertEqual(coordinator.summary?.succeeded, 1)
    }

    private func makeAudio(name: String) {
        let url = inputRoot.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
    }
}
