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
