import Foundation
import SwiftData

struct AnalysisRecordReconciler<Record: TranscriptDerivedAnalysisRecord> {
    struct Outcome {
        var resumeContext: AnalysisResumeContext?
        var repairedGroupCount = 0
        /// At most one, and empty when a server job resumes.
        var deviceResumeEpisodeIDs: [String] = []
    }

    let fileStore: any AnalysisDocumentFileStore
    let messages: AnalysisRecordReconcileMessages
    let resumeTTL: TimeInterval
    var interruptedFailureKind: EpisodeAnalysisFailureKind = .generic
    /// Runs after the `jobAcceptedAt` cleanup; returns whether it changed the record.
    var repairFailedRecord: (Record, Date) -> Bool = { _, _ in false }
    var resumesDeviceRun: (Record, Date) -> Bool = { _, _ in false }

    func reconcile(_ records: [Record], modelContext: ModelContext) throws -> Outcome {
        var fetchedRecords = records
        let now = Date.now
        var changed = false
        var outcome = Outcome()

        outcome.repairedGroupCount = repairDuplicateRecordGroups(&fetchedRecords, modelContext: modelContext)
        if outcome.repairedGroupCount > 0 {
            changed = true
        }

        for record in fetchedRecords {
            switch record.state {
            case .running:
                // One resumed run per launch, server drain or device run,
                // whichever record comes first; the rest are interrupted.
                let slotFree = outcome.resumeContext == nil && outcome.deviceResumeEpisodeIDs.isEmpty
                if slotFree,
                   let jobAcceptedAt = record.jobAcceptedAt,
                   now.timeIntervalSince(jobAcceptedAt) <= resumeTTL,
                   let context = AnalysisResumeContext(record: record)
                {
                    outcome.resumeContext = context
                    continue
                }
                if slotFree, record.jobAcceptedAt == nil, resumesDeviceRun(record, now) {
                    outcome.deviceResumeEpisodeIDs.append(record.episodeID)
                    continue
                }
                fail(record, message: messages.interrupted, kind: interruptedFailureKind, at: now)
                changed = true
            case .queued:
                fail(record, message: messages.interrupted, kind: interruptedFailureKind, at: now)
                changed = true
            case .completed:
                guard fileStore.documentExists(relativePath: record.analysisRelativePath) else {
                    fail(record, message: messages.documentMissing, kind: .generic, at: now)
                    changed = true
                    continue
                }
                if record.jobAcceptedAt != nil {
                    record.jobAcceptedAt = nil
                    changed = true
                }
            case .failed:
                if record.jobAcceptedAt != nil {
                    record.jobAcceptedAt = nil
                    changed = true
                }
                if repairFailedRecord(record, now) {
                    changed = true
                }
            }
        }

        if changed {
            try modelContext.save()
        }
        return outcome
    }

    /// A survivor that contradicts the episode's transcript is kept but failed, so stale results
    /// never show. Loser documents go before the save: losing is deterministic, so an interrupted
    /// save re-runs the same collapse.
    func collapseDuplicateRecords(
        _ group: [Record],
        subscribedFeedURLs: Set<String>,
        modelContext: ModelContext
    ) -> [Record] {
        guard group.count > 1, let episodeID = group.first?.episodeID else {
            return []
        }

        let transcriptFingerprint = survivingTranscriptFingerprint(
            episodeID: episodeID,
            modelContext: modelContext
        )
        let ordered = group
            .map { record in
                (record: record, score: repairScore(record, transcriptFingerprint: transcriptFingerprint))
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.record.updatedAt != rhs.record.updatedAt {
                    return lhs.record.updatedAt > rhs.record.updatedAt
                }
                if lhs.record.createdAt != rhs.record.createdAt {
                    return lhs.record.createdAt > rhs.record.createdAt
                }
                return EpisodeSidecarRepair.stableOrderingKey(lhs.record)
                    < EpisodeSidecarRepair.stableOrderingKey(rhs.record)
            }
        guard let winner = ordered.first else {
            return []
        }

        if winner.score == 2 {
            fail(winner.record, message: messages.transcriptMismatch, kind: .generic, at: .now)
        }
        if let podcastID = EpisodeSidecarRepair.preferredPodcastID(
            orderedCandidates: ordered.map(\.record.podcastID),
            subscribedFeedURLs: subscribedFeedURLs
        ), winner.record.podcastID != podcastID {
            winner.record.podcastID = podcastID
            winner.record.updatedAt = .now
        }

        var deletedRecords: [Record] = []
        let winnerPath = winner.record.analysisRelativePath
        for loser in ordered.dropFirst() {
            if let loserPath = loser.record.analysisRelativePath, loserPath != winnerPath {
                try? fileStore.delete(relativePath: loserPath)
            }
            modelContext.delete(loser.record)
            deletedRecords.append(loser.record)
        }
        return deletedRecords
    }

    private func fail(_ record: Record, message: String, kind: EpisodeAnalysisFailureKind, at now: Date) {
        record.state = .failed
        record.errorMessage = message
        record.failureKind = kind
        record.jobAcceptedAt = nil
        record.updatedAt = now
    }

    private func repairDuplicateRecordGroups(
        _ fetchedRecords: inout [Record],
        modelContext: ModelContext
    ) -> Int {
        var groupsByEpisodeID: [String: [Record]] = [:]
        for record in fetchedRecords {
            groupsByEpisodeID[record.episodeID, default: []].append(record)
        }
        let duplicateGroups = groupsByEpisodeID.values.filter { $0.count > 1 }
        guard !duplicateGroups.isEmpty else {
            return 0
        }

        let subscribedFeedURLs = EpisodeSidecarRepair.subscribedFeedURLs(modelContext: modelContext)
        var removedIdentities = Set<ObjectIdentifier>()
        for group in duplicateGroups {
            for deleted in collapseDuplicateRecords(
                group,
                subscribedFeedURLs: subscribedFeedURLs,
                modelContext: modelContext
            ) {
                removedIdentities.insert(ObjectIdentifier(deleted))
            }
        }
        fetchedRecords.removeAll { removedIdentities.contains(ObjectIdentifier($0)) }
        return duplicateGroups.count
    }

    /// 2 is a completed record that contradicts the surviving transcript: it wins only when nothing
    /// better exists, and is then failed.
    private func repairScore(_ record: Record, transcriptFingerprint: String?) -> Int {
        guard record.state == .completed,
              let relativePath = record.analysisRelativePath,
              fileStore.documentDecodes(relativePath: relativePath)
        else {
            return 0
        }
        if let transcriptFingerprint {
            return record.transcriptFingerprint == transcriptFingerprint ? 4 : 2
        }
        return 3
    }

    private func survivingTranscriptFingerprint(
        episodeID: String,
        modelContext: ModelContext
    ) -> String? {
        let targetEpisodeID = episodeID
        let transcriptRecords = (try? modelContext.fetch(
            FetchDescriptor<EpisodeTranscriptRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetEpisodeID
                }
            )
        )) ?? []
        let completedRecords = transcriptRecords.filter {
            $0.state == .completed && $0.transcriptRelativePath != nil
        }
        let transcriptFileStore = EpisodeTranscriptFileStore(baseDirectory: fileStore.baseDirectory)
        guard completedRecords.count == 1,
              let relativePath = completedRecords[0].transcriptRelativePath,
              let document = try? transcriptFileStore.read(relativePath: relativePath)
        else {
            return nil
        }
        return fileStore.transcriptFingerprint(for: document)
    }
}
