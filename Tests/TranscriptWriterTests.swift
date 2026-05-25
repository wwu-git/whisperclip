import XCTest
@testable import WhisperClip

final class TranscriptWriterTests: XCTestCase {
    private var base: URL!
    private var inputRoot: URL!
    private var outputRoot: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-\(UUID().uuidString)", isDirectory: true)
        inputRoot = base.appendingPathComponent("in", isDirectory: true)
        outputRoot = base.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
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
        XCTAssertTrue(planned.path.hasSuffix("/out/week1/a.txt") || planned.path.contains("week1/a.txt"))
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
        XCTAssertNotNil(written)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written!.path))
        let content = try String(contentsOf: written!, encoding: .utf8)
        XCTAssertEqual(content, "hello batch")
    }

    func testSkipExistingDoesNotWrite() throws {
        let audio = inputRoot.appendingPathComponent("only.mp3")
        FileManager.default.createFile(atPath: audio.path, contents: Data([0x00]))
        let planned = TranscriptWriter.plannedOutputURL(
            inputFile: audio,
            inputRoot: inputRoot,
            outputRoot: outputRoot
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
            inputFile: audio,
            inputRoot: inputRoot,
            outputRoot: outputRoot
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
            inputFile: audio,
            inputRoot: inputRoot,
            outputRoot: outputRoot
        )
        try "exists".write(to: planned, atomically: true, encoding: .utf8)

        let files = try AudioFileEnumerator.enumerate(root: inputRoot)
        XCTAssertTrue(TranscriptWriter.hasAnyOutputConflict(
            inputFiles: files,
            inputRoot: inputRoot,
            outputRoot: outputRoot
        ))
    }
}
