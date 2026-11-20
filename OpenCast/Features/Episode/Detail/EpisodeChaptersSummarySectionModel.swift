import Foundation
import Observation

@Observable
final class EpisodeChaptersSummarySectionModel {
    private static let placeholderState: EpisodeTranscriptAnalysisJobState = .unavailable("Transcript unavailable.")

    private(set) var transcriptDocument: EpisodeTranscriptDocument?
    private(set) var analysisDocument: EpisodeTranscriptAnalysisDocument?
    private(set) var jobState: EpisodeTranscriptAnalysisJobState = placeholderState
    private(set) var hasCurrentCompletedAnalysis = false
    private(set) var creatorChaptersURL: String?
    private(set) var loadedKey: String?

    /// Record lookups here are not Observation-tracked, so isRunning is what re-renders a run's
    /// start and end. The store-global changeSequence stays out: it would re-run this load (a
    /// document read and an off-main SHA-256) on every other episode's analysis events.
    func loadKey(appModel: OpenCastAppModel, episodeID: String?) -> String {
        guard let episodeID else {
            return "missing"
        }

        let transcriptRecord = appModel.transcriptions.record(for: episodeID)
        let transcriptStamp = transcriptRecord?.state == .completed
            ? "completed:\(transcriptRecord?.updatedAt.timeIntervalSinceReferenceDate ?? -1)"
            : "incomplete"
        let analysisStamp: String
        if let analysisRecord = appModel.transcriptAnalyses.record(for: episodeID) {
            analysisStamp = "\(analysisRecord.state.rawValue):\(analysisRecord.updatedAt.timeIntervalSinceReferenceDate)"
        } else {
            analysisStamp = "missing"
        }
        let runningStamp = appModel.transcriptAnalyses.isRunning(for: episodeID) ? "active" : "idle"
        return "\(episodeID)|\(transcriptStamp)|\(analysisStamp)|\(runningStamp)"
    }

    func isLoaded(forKey key: String, episodeID: String) -> Bool {
        loadedKey == key && transcriptDocument?.episodeID == episodeID
    }

    func hasCurrentAnalysis(forKey key: String, episodeID: String) -> Bool {
        loadedKey == key
            && hasCurrentCompletedAnalysis
            && analysisDocument?.episodeID == episodeID
    }

    func transcriptDocument(for episodeID: String) -> EpisodeTranscriptDocument? {
        guard let transcriptDocument, transcriptDocument.episodeID == episodeID else {
            return nil
        }
        return transcriptDocument
    }

    func load(appModel: OpenCastAppModel, episode: EpisodeListItemSnapshot?, key: String) async {
        loadedKey = nil
        transcriptDocument = nil
        analysisDocument = nil
        jobState = Self.placeholderState
        hasCurrentCompletedAnalysis = false
        creatorChaptersURL = nil

        guard let episode,
              appModel.transcriptions.record(for: episode.episodeID)?.state == .completed
        else {
            loadedKey = key
            return
        }

        let detail = await appModel.library.episodeDetail(for: episode.episodeID)
        guard !Task.isCancelled else {
            return
        }

        // A nil document settles this key until the user re-enters (nothing re-keys the
        // task), so a transient read failure retries briefly first.
        var loadedTranscriptDocument: EpisodeTranscriptDocument?
        for attempt in 1...3 {
            do {
                loadedTranscriptDocument = try await appModel.transcriptions.loadDocument(for: episode.episodeID)
                break
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, attempt < 3 else {
                    break
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        guard !Task.isCancelled else {
            return
        }
        guard let transcriptDocument = loadedTranscriptDocument else {
            creatorChaptersURL = detail?.chaptersURL
            loadedKey = key
            return
        }

        let analysisDocument: EpisodeTranscriptAnalysisDocument?
        if appModel.transcriptAnalyses.record(for: episode.episodeID)?.state == .completed {
            do {
                analysisDocument = try await appModel.transcriptAnalyses.loadDocument(for: episode.episodeID)
            } catch is CancellationError {
                return
            } catch {
                analysisDocument = nil
            }
        } else {
            analysisDocument = nil
        }
        guard !Task.isCancelled else {
            return
        }

        let state = await appModel.transcriptAnalyses.episodeDetailState(
            for: transcriptDocument,
            transcriptState: appModel.transcriptions.record(for: episode.episodeID)?.state,
            analysisDocument: analysisDocument
        )
        guard !Task.isCancelled else {
            return
        }
        self.transcriptDocument = transcriptDocument
        self.analysisDocument = analysisDocument
        jobState = state.jobState
        hasCurrentCompletedAnalysis = state.hasCurrentCompletedAnalysis
        creatorChaptersURL = detail?.chaptersURL
        loadedKey = key
    }
}
