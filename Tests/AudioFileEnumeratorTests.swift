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
