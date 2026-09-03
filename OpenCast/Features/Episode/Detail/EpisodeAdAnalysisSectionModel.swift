import Foundation
import Observation

/// The episode detail's ad-analysis surface: the transcript and analysis
/// documents behind the pipeline card and span timeline, loaded once per
/// `loadKey` and served only while that key is still the current one.
@Observable
final class EpisodeAdAnalysisSectionModel {
    private static let placeholderState: EpisodeAdAnalysisJobState = .unavailable("Transcript unavailable.")

    private(set) var transcriptDocument: EpisodeTranscriptDocument?
    private(set) var analysisDocument: EpisodeAdAnalysisDocument?
    private(set) var jobState: EpisodeAdAnalysisJobState = placeholderState
    private(set) var hasCurrentCompletedAnalysis = false
    private(set) var zoneTiers: EpisodeAdAnalysisZoneTiers = .empty
    private(set) var loadedKey: String?

    /// The `.task(id:)` key: per-episode transcript and analysis record
    /// stamps plus the store's tracked running flag. isRunning is the only
    /// Observation-tracked store read here (record lookups go through the
    /// store's index), so run start/end are what invalidate the view; the
    /// store-global changeSequence stays out because it would re-run this
    /// load — a document read plus an off-main SHA-256 — on every OTHER
    /// episode's analysis events.
    func loadKey(appModel: OpenCastAppModel, episodeID: String?) -> String {
        guard let episodeID else {
            return "missing"
        }

        let transcriptRecord = appModel.transcriptions.record(for: episodeID)
        let transcriptStamp = transcriptRecord?.state == .completed
            ? "completed:\(transcriptRecord?.updatedAt.timeIntervalSinceReferenceDate ?? -1)"
            : "incomplete"
        let analysisStamp: String
        if let analysisRecord = appModel.adAnalyses.record(for: episodeID) {
            analysisStamp = "\(analysisRecord.state.rawValue):\(analysisRecord.updatedAt.timeIntervalSinceReferenceDate)"
        } else {
            analysisStamp = "missing"
        }
        let runningStamp = appModel.adAnalyses.isRunning(for: episodeID) ? "active" : "idle"
        return "\(episodeID)|\(transcriptStamp)|\(analysisStamp)|\(runningStamp)"
    }

    /// The loaded job state while it still belongs to `key`; a re-keyed task
    /// must never render a stale episode's state before its load lands.
    func jobState(forKey key: String) -> EpisodeAdAnalysisJobState {
        loadedKey == key ? jobState : Self.placeholderState
    }

    func hasCurrentAnalysis(forKey key: String, episodeID: String) -> Bool {
        loadedKey == key
            && hasCurrentCompletedAnalysis
            && analysisDocument?.episodeID == episodeID
    }

    func zoneTiers(forKey key: String, episodeID: String) -> EpisodeAdAnalysisZoneTiers {
        hasCurrentAnalysis(forKey: key, episodeID: episodeID) ? zoneTiers : .empty
    }

    /// The transcript a manual Detect Ads run submits, only while it is the
    /// one this key loaded.
    func transcriptDocument(forKey key: String, episodeID: String) -> EpisodeTranscriptDocument? {
        guard loadedKey == key, let transcriptDocument, transcriptDocument.episodeID == episodeID else {
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
        zoneTiers = .empty

        guard let episode,
              appModel.transcriptions.record(for: episode.episodeID)?.state == .completed
        else {
            loadedKey = key
            return
        }

        let transcriptDocument: EpisodeTranscriptDocument
        do {
            transcriptDocument = try await appModel.transcriptions.loadDocument(for: episode.episodeID)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else {
                return
            }
            loadedKey = key
            return
        }
        guard !Task.isCancelled else {
            return
        }

        let analysisDocument: EpisodeAdAnalysisDocument?
        if appModel.adAnalyses.record(for: episode.episodeID)?.state == .completed {
            do {
                analysisDocument = try await appModel.adAnalyses.loadDocument(for: episode.episodeID)
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

        let state = await appModel.adAnalyses.episodeDetailState(
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
        if state.hasCurrentCompletedAnalysis, let analysisDocument {
            zoneTiers = EpisodeAdAnalysisZoneMapper.zoneTiers(
                for: analysisDocument,
                duration: episode.duration
            )
        } else {
            zoneTiers = .empty
        }
        loadedKey = key
    }
}
