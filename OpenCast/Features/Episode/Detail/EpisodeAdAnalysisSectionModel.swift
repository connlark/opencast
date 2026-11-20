import Foundation
import Observation

@Observable
final class EpisodeAdAnalysisSectionModel {
    private static let placeholderState: EpisodeAdAnalysisJobState = .unavailable("Transcript unavailable.")

    private(set) var transcriptDocument: EpisodeTranscriptDocument?
    private(set) var analysisDocument: EpisodeAdAnalysisDocument?
    private(set) var jobState: EpisodeAdAnalysisJobState = placeholderState
    private(set) var hasCurrentCompletedAnalysis = false
    /// From the download record's state and stored hash, with no file I/O: a file lost
    /// mid-session still reads attached until the next launch reconciles it.
    private(set) var isAnalysisAttached = false
    private(set) var zoneTiers: EpisodeAdAnalysisZoneTiers = .empty
    private(set) var loadedKey: String?

    /// Record lookups here are not Observation-tracked; isRunning is. The store-global
    /// changeSequence stays out: it would re-run this load (a document read and an off-main
    /// SHA-256) on every other episode's analysis events.
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
        let downloadStamp = appModel.downloads.record(for: episodeID)
            .map { "\($0.state.rawValue):\($0.sourceFileSHA256)" } ?? "none"
        return "\(episodeID)|\(transcriptStamp)|\(analysisStamp)|\(runningStamp)|\(downloadStamp)"
    }

    /// A re-keyed task must never render the previous episode's state before its own load lands.
    func jobState(forKey key: String) -> EpisodeAdAnalysisJobState {
        loadedKey == key ? jobState : Self.placeholderState
    }

    func hasCurrentAnalysis(forKey key: String, episodeID: String) -> Bool {
        loadedKey == key
            && hasCurrentCompletedAnalysis
            && analysisDocument?.episodeID == episodeID
    }

    func isAnalysisAttached(forKey key: String, episodeID: String) -> Bool {
        loadedKey == key
            && isAnalysisAttached
            && transcriptDocument?.episodeID == episodeID
    }

    func zoneTiers(forKey key: String, episodeID: String) -> EpisodeAdAnalysisZoneTiers {
        hasCurrentAnalysis(forKey: key, episodeID: episodeID) ? zoneTiers : .empty
    }

    func timelineDuration(forKey key: String, episode: EpisodeListItemSnapshot) -> TimeInterval {
        if let duration = transcriptDocument(forKey: key, episodeID: episode.episodeID)?.audioDuration,
           duration.isFinite, duration > 0 {
            return duration
        }
        if let duration = episode.duration, duration.isFinite, duration > 0 {
            return duration
        }
        let tiers = zoneTiers(forKey: key, episodeID: episode.episodeID)
        return (tiers.autoSkip + tiers.displayOnly).map(\.endTime).max() ?? 0
    }

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
        isAnalysisAttached = false
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
                analysisDocument = try await appModel.adAnalyses.loadDocument(
                    for: episode.episodeID, transcript: transcriptDocument
                )
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
        isAnalysisAttached = appModel.isAdAnalysisAttachedByRecord(for: episode.episodeID)
        if state.hasCurrentCompletedAnalysis, let analysisDocument {
            zoneTiers = EpisodeAdAnalysisZoneMapper.zoneTiers(
                for: analysisDocument,
                duration: transcriptDocument.audioDuration
            )
        } else {
            zoneTiers = .empty
        }
        loadedKey = key
    }
}
