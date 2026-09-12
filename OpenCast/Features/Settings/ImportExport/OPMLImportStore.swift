import Foundation
import Observation
import OpenCastCore
import SwiftData

@Observable
final class OPMLImportStore {
    private nonisolated static let maximumImportFileByteCount = 10 * 1_024 * 1_024
    /// Hard cap on unique outlines per import; beyond it the import aborts
    /// before subscribing anything (security triage P2).
    nonisolated static let maximumImportedFeedCount = 300

    private(set) var state = OPMLImportState.idle

    func importOPML(
        data: Data,
        libraryStore: LibraryStore,
        modelContext: ModelContext
    ) async {
        state = .importing

        do {
            try await importLoadedOPML(
                data: data,
                libraryStore: libraryStore,
                modelContext: modelContext
            )
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func importOPML(
        from url: URL,
        libraryStore: LibraryStore,
        modelContext: ModelContext
    ) async {
        state = .importing

        do {
            let data = try await Self.loadOPMLData(from: url)
            try Task.checkCancellation()
            try await importLoadedOPML(
                data: data,
                libraryStore: libraryStore,
                modelContext: modelContext
            )
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func reportFailure(_ message: String) {
        state = .failed(message)
    }

    private func importLoadedOPML(
        data: Data,
        libraryStore: LibraryStore,
        modelContext: ModelContext
    ) async throws {
        let parseResult = try OPMLParser().parseResult(data: data)
        guard parseResult.feedReferences.count <= Self.maximumImportedFeedCount else {
            throw OPMLImportFileReadError.tooManyFeeds(
                count: parseResult.feedReferences.count,
                limit: Self.maximumImportedFeedCount
            )
        }
        await libraryStore.load(modelContext: modelContext)

        // Duplicate suppression is decided up front on the main actor, so the
        // concurrent fetch window can never race two subscribes for one feed.
        var skippedDuplicateCount = parseResult.duplicateFeedReferenceCount
        // Defense if parser output ever stops being unique by canonical feed URL.
        var importedFeedURLs: Set<String> = []
        let activeFeedURLs = libraryStore.activePodcastIDs
        var pendingReferences: [OPMLFeedReference] = []

        for reference in parseResult.feedReferences {
            let canonicalFeedURL = reference.canonicalFeedURL
            guard importedFeedURLs.insert(canonicalFeedURL).inserted,
                  !activeFeedURLs.contains(canonicalFeedURL)
            else {
                skippedDuplicateCount += 1
                continue
            }
            pendingReferences.append(reference)
        }

        let referencesByFeedURLString = Dictionary(
            pendingReferences.map { ($0.feedURL.absoluteString, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let batchResult = try await libraryStore.subscribeBatch(
            to: pendingReferences.map(\.feedURL.absoluteString),
            modelContext: modelContext
        )
        let failures = batchResult.failures.map { failure in
            let reference = referencesByFeedURLString[failure.feedURLString]
            return OPMLImportFailure(
                feedURL: reference?.canonicalFeedURL ?? failure.feedURLString,
                title: reference?.title,
                message: failure.message
            )
        }

        await libraryStore.load(modelContext: modelContext)
        state = .imported(
            OPMLImportResult(
                totalFeedReferencesFound: parseResult.usableFeedReferenceCount,
                importedCount: batchResult.subscribedFeedURLStrings.count,
                skippedDuplicateCount: skippedDuplicateCount,
                failures: failures
            )
        )
    }

    @concurrent
    private static func loadOPMLData(from url: URL) async throws -> Data {
        let didAccessResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resourceValues.fileSize,
           fileSize > maximumImportFileByteCount {
            throw OPMLImportFileReadError.fileTooLarge
        }

        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()

        guard data.count <= maximumImportFileByteCount else {
            throw OPMLImportFileReadError.fileTooLarge
        }

        return data
    }
}
