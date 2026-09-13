import Foundation
import WidgetKit
import os

actor ResumeWidgetPublisher {
    static let shared = ResumeWidgetPublisher()
    private var lastCandidate: ResumeWidgetCandidate?
    private var hasPublished = false
    private var generation = 0
    private let directory: URL?
    private let loadArtwork: @Sendable (URL?) async -> Data?
    private let reload: @Sendable () -> Void
    private let logger = Logger(subsystem: "com.connor.opencast", category: "ResumeWidget")

    init(
        directory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ResumeWidgetSnapshot.appGroup),
        loadArtwork: @escaping @Sendable (URL?) async -> Data? = { await ResumeWidgetArtwork.load($0) },
        reload: @escaping @Sendable () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: ResumeWidgetSnapshot.kind) }
    ) {
        self.directory = directory
        self.loadArtwork = loadArtwork
        self.reload = reload
    }

    func publish(_ candidate: ResumeWidgetCandidate?) async {
        // Even a return to the committed snapshot supersedes an in-flight image.
        generation += 1
        let request = generation
        guard !hasPublished || candidate != lastCandidate else { return }
        let artwork = await loadArtwork(candidate?.artworkURL)
        guard request == generation, !Task.isCancelled else { return }
        do {
            guard let directory else {
                throw CocoaError(.fileNoSuchFile)
            }
            let url = directory.appending(path: ResumeWidgetSnapshot.filename)
            if let candidate {
                let value = ResumeWidgetSnapshot(episodeID: candidate.episodeID, title: candidate.title, showTitle: candidate.showTitle, updatedAt: .now, progressBucket: candidate.progressBucket, artwork: artwork)
                try value.validate()
                let data = try JSONEncoder().encode(value)
                guard data.count <= ResumeWidgetSnapshot.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var snapshotURL = url
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try snapshotURL.setResourceValues(resourceValues)
            } else {
                do { try FileManager.default.removeItem(at: url) }
                catch CocoaError.fileNoSuchFile { }
            }
            hasPublished = true
            lastCandidate = candidate
            reload()
        } catch {
            logger.error("Unable to publish the local Resume widget snapshot.")
        }
    }
}
