import Foundation

struct OPMLImportResult: Sendable, Equatable {
    var totalFeedReferencesFound: Int
    var importedCount: Int
    var skippedDuplicateCount: Int
    var failures: [OPMLImportFailure]

    var failedCount: Int {
        failures.count
    }
}
