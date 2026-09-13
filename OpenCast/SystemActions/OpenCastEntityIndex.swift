import AppIntents
import CoreSpotlight
import Foundation
import os

actor OpenCastEntityIndex {
    static let shared = OpenCastEntityIndex()
    private let directory = URL.applicationSupportDirectory.appending(path: "SystemEntityIndex", directoryHint: .isDirectory)
    private var pending: OpenCastEntityCatalog?
    private var requiresRebuild = false
    private var isUpdating = false
    private var lastUpdateError: (any Error)?
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private let logger = Logger(subsystem: "com.connor.opencast", category: "SystemEntityIndex")

    func update(_ catalog: OpenCastEntityCatalog, rebuild: Bool = false) async {
        pending = catalog
        requiresRebuild = requiresRebuild || rebuild
        guard !isUpdating else { return }
        isUpdating = true
        defer {
            isUpdating = false
            let result: Result<Void, any Error> = lastUpdateError.map { .failure($0) } ?? .success(())
            let completed = waiters.values
            waiters.removeAll()
            completed.forEach { $0.resume(with: result) }
        }
        while let next = pending {
            pending = nil
            let force = requiresRebuild
            requiresRebuild = false
            do {
                try await synchronize(next, rebuild: force)
                lastUpdateError = nil
            } catch {
                lastUpdateError = error
                requiresRebuild = true
                logger.error("Unable to update the local content index.")
            }
        }
    }

    func rebuild(_ catalog: OpenCastEntityCatalog) async throws {
        try Task.checkCancellation()
        await update(catalog, rebuild: true)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isUpdating {
                    waiters[id] = continuation
                } else if let lastUpdateError {
                    continuation.resume(throwing: lastUpdateError)
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func synchronize(_ catalog: OpenCastEntityCatalog, rebuild: Bool) async throws {
        let revisionURL = directory.appending(path: "revision.json")
        let dirtyURL = directory.appending(path: "interrupted")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = try? JSONDecoder().decode(OpenCastIndexRevision.self, from: Data(contentsOf: revisionURL))
        let next = OpenCastIndexRevision(catalog: catalog)
        let rebuild = rebuild || previous?.version != next.version || FileManager.default.fileExists(atPath: dirtyURL.path)
        guard rebuild || previous != next else { return }
        try Data().write(to: dirtyURL, options: .atomic)
        let index = CSSearchableIndex.default()
        if rebuild {
            try await index.deleteAppEntities(ofType: OpenCastPodcastEntity.self)
            try await index.deleteAppEntities(ofType: OpenCastEpisodeEntity.self)
        } else if let previous {
            try await index.deleteAppEntities(identifiedBy: Array(Set(previous.shows.keys).subtracting(next.shows.keys)), ofType: OpenCastPodcastEntity.self)
            try await index.deleteAppEntities(identifiedBy: Array(Set(previous.episodes.keys).subtracting(next.episodes.keys)), ofType: OpenCastEpisodeEntity.self)
        }
        let shows = catalog.shows.filter { rebuild || previous?.shows[$0.id] != next.shows[$0.id] }
        let episodes = catalog.episodes.filter { rebuild || previous?.episodes[$0.id] != next.episodes[$0.id] }
        for offset in stride(from: 0, to: shows.count, by: 100) {
            try await index.indexAppEntities(Array(shows[offset..<min(offset + 100, shows.count)]))
        }
        for offset in stride(from: 0, to: episodes.count, by: 100) {
            try await index.indexAppEntities(Array(episodes[offset..<min(offset + 100, episodes.count)]))
        }
        try JSONEncoder().encode(next).write(to: revisionURL, options: .atomic)
        try FileManager.default.removeItem(at: dirtyURL)
    }
}
