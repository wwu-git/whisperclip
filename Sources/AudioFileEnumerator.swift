import Foundation

enum AudioFileEnumerator {
    static let supportedExtensions: Set<String> = [
        "mp3", "wav", "m4a", "flac", "ogg", "aiff", "aac", "caf"
    ]

    static func enumerate(root: URL) throws -> [URL] {
        let rootURL = root.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
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
        return results.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}
