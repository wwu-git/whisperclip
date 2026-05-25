import Foundation

enum TranscriptWriter {
    static func plannedOutputURL(inputFile: URL, inputRoot: URL, outputRoot: URL) -> URL {
        let inputRootURL = inputRoot.standardizedFileURL
        let fileURL = inputFile.standardizedFileURL
        let rootPath = inputRootURL.path
        let relativePath = fileURL.path.hasPrefix(rootPath + "/")
            ? String(fileURL.path.dropFirst(rootPath.count + 1))
            : fileURL.lastPathComponent
        let relativeDir = (relativePath as NSString).deletingLastPathComponent
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
            inputFile: inputFile,
            inputRoot: inputRoot,
            outputRoot: outputRoot
        )

        if conflictPolicy == .skipExisting,
           FileManager.default.fileExists(atPath: destination.path) {
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
        if !FileManager.default.fileExists(atPath: base.path) {
            return base
        }
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
