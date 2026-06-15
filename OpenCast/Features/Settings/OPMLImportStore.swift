import Foundation
import Observation
import OpenCastCore
import SwiftData

@Observable
final class OPMLImportStore {
    private nonisolated static let maximumImportFileByteCount = 10 * 1_024 * 1_024

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
        await libraryStore.load(modelContext: modelContext)

        var importedCount = 0
        var skippedDuplicateCount = parseResult.duplicateFeedReferenceCount
        var failures: [OPMLImportFailure] = []
        // Defense if parser output ever stops being unique by canonical feed URL.
        var importedFeedURLs: Set<String> = []
        var activeFeedURLs = libraryStore.activePodcastIDs

        for reference in parseResult.feedReferences {
            try Task.checkCancellation()

            let canonicalFeedURL = reference.canonicalFeedURL
            guard importedFeedURLs.insert(canonicalFeedURL).inserted else {
                skippedDuplicateCount += 1
                continue
            }

            guard !activeFeedURLs.contains(canonicalFeedURL) else {
                skippedDuplicateCount += 1
                continue
            }

            do {
                try await libraryStore.subscribe(
                    to: reference.feedURL.absoluteString,
                    modelContext: modelContext,
                    reloadAfter: false
                )
                importedCount += 1
                activeFeedURLs.insert(canonicalFeedURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(
                    OPMLImportFailure(
                        feedURL: canonicalFeedURL,
                        title: reference.title,
                        message: error.localizedDescription
                    )
                )
            }
        }

        await libraryStore.load(modelContext: modelContext)
        state = .imported(
            OPMLImportResult(
                totalFeedReferencesFound: parseResult.usableFeedReferenceCount,
                importedCount: importedCount,
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
