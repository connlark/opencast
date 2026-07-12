#if DEBUG
import Foundation
import OpenCastTranscription
import SwiftData

/// Seeds a completed transcript and ad analysis for the primary Signal Path
/// episode so the App Store set can show the ad-marked timeline, the badged
/// transcript, and the completed Sound Lab state from records alone.
enum AppStoreScreenshotSeedTranscript {
    /// All span times sit inside the 300s seed WAV: the Now Playing slider
    /// tracks the real AVPlayer item duration, not the episode metadata.
    private static let audioDuration: TimeInterval = 300

    static func seed(in context: ModelContext, audioURL: String, createdAt: Date) throws {
        let episodeID = AppStoreScreenshotSeedCatalog.primaryEpisodeID
        let podcastID = AppStoreScreenshotSeedCatalog.primaryFeedURL
        let modelSummary = OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.largeV3.rawValue,
            version: OpenCastWhisperModel.largeV3.defaultRemoteVersion,
            totalByteCount: 629_482_970,
            treeSHA256: "20a910bd8ea9f94a3e4438780f6e2f0aa3bbcd3fc1f8e99fccb2d64b68935603"
        )

        let transcriptFileStore = EpisodeTranscriptFileStore()
        let sourceSHA = "app-store-screenshot-source-sha"
        let fingerprint = transcriptFileStore.fingerprint(
            sourceFileSHA256: sourceSHA,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256
        )
        let transcriptRelativePath = transcriptFileStore.relativePath(
            episodeID: episodeID,
            fingerprint: fingerprint
        )
        let segments = transcriptSegments()
        let transcriptDocument = EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: episodeID,
            podcastID: podcastID,
            sourceAudioURL: audioURL,
            sourceFileByteCount: 4_800_044,
            sourceFileSHA256: sourceSHA,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256,
            languageCode: "en",
            audioDuration: audioDuration,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try transcriptFileStore.write(transcriptDocument, relativePath: transcriptRelativePath)
        context.insert(EpisodeTranscriptRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            sourceAudioURL: audioURL,
            sourceFileByteCount: 4_800_044,
            sourceFileSHA256: sourceSHA,
            modelIdentifier: modelSummary.modelIdentifier,
            modelVersion: modelSummary.version,
            modelTreeSHA256: modelSummary.treeSHA256,
            languageCode: "en",
            state: .completed,
            audioDuration: audioDuration,
            completedDuration: audioDuration,
            checkpointCount: 0,
            transcriptRelativePath: transcriptRelativePath,
            createdAt: createdAt,
            updatedAt: createdAt
        ))

        let analysisFileStore = EpisodeAdAnalysisFileStore()
        let analysisFingerprint = analysisFileStore.transcriptFingerprint(for: transcriptDocument)
        let analysisRelativePath = analysisFileStore.relativePath(
            episodeID: episodeID,
            transcriptFingerprint: analysisFingerprint
        )
        let spans = adSpans()
        // Marketing shots must never surface a vendor model name; an empty
        // model string keeps the record valid while hiding that detail.
        let analysisDocument = EpisodeAdAnalysisDocument(
            schemaVersion: 1,
            episodeID: episodeID,
            podcastID: podcastID,
            requestID: "app-store-screenshot-ad-analysis",
            transcriptFingerprint: analysisFingerprint,
            transcriptUpdatedAt: transcriptDocument.updatedAt,
            transcriptSegmentCount: transcriptDocument.segments.count,
            model: "",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: spans,
            warnings: [],
            usage: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try analysisFileStore.write(analysisDocument, relativePath: analysisRelativePath)
        context.insert(EpisodeAdAnalysisRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            transcriptFingerprint: analysisFingerprint,
            transcriptUpdatedAt: transcriptDocument.updatedAt,
            transcriptSegmentCount: transcriptDocument.segments.count,
            state: .completed,
            analysisRelativePath: analysisRelativePath,
            model: analysisDocument.model,
            policy: analysisDocument.policy,
            spanCount: analysisDocument.spans.count,
            warningCount: analysisDocument.warnings.count,
            createdAt: createdAt,
            updatedAt: createdAt
        ))
    }

    /// Three ≥0.8-confidence spans map to solid auto-skip zones ("3 zones
    /// marked."); the 0.62 cross-promo renders as a dimmed display-only zone.
    /// Same-tier gaps stay over the mapper's 1s merge threshold and the
    /// first zone past the seeded 92s playhead starts at 205s, so nothing
    /// auto-skips while the captures run.
    private static func adSpans() -> [EpisodeAdAnalysisSpan] {
        [
            EpisodeAdAnalysisSpan(
                id: 0,
                kind: .hostReadAd,
                label: "Bottomless Mug Coffee Co.",
                startSegmentID: 4,
                endSegmentID: 8,
                startTime: 28,
                endTime: 58,
                confidence: 0.93,
                evidenceQuote: "brought to you by Bottomless Mug Coffee Co."
            ),
            EpisodeAdAnalysisSpan(
                id: 1,
                kind: .hostReadAd,
                label: "Possible cross-promo",
                startSegmentID: 18,
                endSegmentID: 20,
                startTime: 132,
                endTime: 158,
                confidence: 0.62,
                evidenceQuote: "our friends over at Release Window"
            ),
            EpisodeAdAnalysisSpan(
                id: 2,
                kind: .insertedAd,
                label: "Mid-roll ad break",
                startSegmentID: 26,
                endSegmentID: 29,
                startTime: 205,
                endTime: 232,
                confidence: 0.90,
                evidenceQuote: "first, a quick break"
            ),
            EpisodeAdAnalysisSpan(
                id: 3,
                kind: .insertedAd,
                label: "End-of-show promo",
                startSegmentID: 36,
                endSegmentID: 38,
                startTime: 272,
                endTime: 296,
                confidence: 0.88,
                evidenceQuote: "Members get ad-free episodes"
            )
        ]
    }

    private static func transcriptSegments() -> [OpenCastTranscriptSegment] {
        let lines: [(start: TimeInterval, end: TimeInterval, text: String)] = [
            (0, 7, "It's two in the morning, my pager is screaming, and the dashboard says everything is fine. Everything is not fine."),
            (7, 14, "This week: the bug that only appeared at night. Not late in the sprint — literally at night. After midnight, every single time."),
            (14, 21, "By sunrise it was gone. No stack trace, no bad deploy, nothing to bisect. Just a graph that went sideways while we slept."),
            (21, 28, "I'm Marin Vale, this is Signal Path, and I spent eleven nights chasing this thing. Here's how it finally cracked."),
            (28, 34, "This episode is brought to you by Bottomless Mug Coffee Co. — the coffee subscription that notices when you're compiling at 3 a.m. and ships accordingly."),
            (34, 40, "Their roasters watch your actual consumption, so the next bag lands the same morning the last one runs out."),
            (40, 46, "I've been on their Night Shift blend for two months. It tastes like a code review that ends with 'looks good to me.'"),
            (46, 52, "Every bag comes with a no-questions refund, even if your only question is how it got to your door that fast."),
            (52, 58, "Go to bottomlessmug dot coffee and use code SIGNAL for a free first bag. That's code SIGNAL. Now — back to the pager."),
            (58, 66, "So. First rule of a bug you can't reproduce: write down what you actually saw, not what you think you saw."),
            (66, 74, "What we actually saw was queue delay. Every job that touched the export service crawled between midnight and four."),
            (74, 82, "Naturally, I blamed the batch jobs. There's always a batch job. We moved them an hour earlier — the bug didn't move with them."),
            (82, 90, "Then I blamed the backup window. Storage swore the snapshots finished by eleven, and the graphs backed them up. Strike two."),
            (90, 98, "Here's where I lost a full night to the wrong dashboard. Our latency panel averaged across regions, and averages are liars."),
            (98, 106, "Split by region, the picture changed completely. One zone hummed along all night. The other fell off a cliff at 12:04."),
            (106, 114, "12:04 is a suspiciously specific time. Nothing human happens at 12:04. Machines happen at 12:04."),
            (114, 123, "So we listed everything in that zone with a clock: cron, cert rotation, log shipping, and a license check nobody remembered owning."),
            (123, 132, "I want to pause on that list, because the thing that eventually saved us wasn't a profiler. It was an inventory."),
            (132, 141, "Speaking of inventories — our friends over at Release Window just did a whole episode on rollout checklists, and it pairs weirdly well with this one."),
            (141, 150, "If you like the postmortem half of this show, their back catalog is basically that, minus my pager anxiety."),
            (150, 158, "Alright. Where were we. Right — 12:04, and a list of suspects who all had alibis."),
            (158, 168, "We put a stopwatch on every suspect. Cron was innocent. Cert rotation was innocent. Log shipping was — mostly innocent."),
            (168, 177, "The license check, though. The license check ran at midnight local time. And here's the thing: local time isn't one time."),
            (177, 186, "Our zones roll past midnight one after another, so the check marched across the fleet like a slow wave, region by region."),
            (186, 196, "Every instance phoned the same tiny vendor endpoint. At 12:04 our biggest zone crossed midnight, and that endpoint started queueing us."),
            (196, 205, "A four-minute retry backoff, one shared connection pool, and suddenly export jobs are waiting behind a license ping. That's the whole bug."),
            (205, 212, "We'll get to the fix in a second — first, a quick break."),
            (212, 219, "This show is supported by Fieldnote, the incident review tool built for teams smaller than their incident channel."),
            (219, 226, "Fieldnote turns a messy timeline of pastes and screenshots into a postmortem people actually read."),
            (226, 232, "Start a free thirty-day trial at fieldnote dot app slash signal."),
            (232, 239, "Okay. The fix. Short version: we stopped letting a license check share a connection pool with production work."),
            (239, 246, "Long version: the check moved to its own client, picked up an hour of jitter, and lost the retry storm entirely."),
            (246, 253, "The vendor, to their credit, confirmed the midnight pile-up from their side within a day of us asking."),
            (253, 260, "The export queue flattened out that same night. 12:04 came and went, and the graph just... stayed boring."),
            (260, 266, "We left tripwires behind, too: a per-dependency latency panel, split by region, with averages banned."),
            (266, 272, "Because the real lesson isn't 'timezones are hard.' It's that invisible dependencies deserve dashboards too."),
            (272, 280, "If this episode saves you a night of sleep, the best thank-you is a review — it genuinely helps other engineers find the show."),
            (280, 288, "Members get ad-free episodes and the annotated incident timeline from tonight's story at signalpath dot fm slash support."),
            (288, 296, "Members also get the extended cut of next week's episode early: the deploy that worked everywhere except on Tuesdays."),
            (296, 300, "I'm Marin Vale. This was Signal Path. Get some sleep.")
        ]

        return lines.enumerated().map { index, line in
            OpenCastTranscriptSegment(
                id: index,
                start: line.start,
                end: line.end,
                text: line.text,
                avgLogProbability: -0.12,
                noSpeechProbability: 0.01
            )
        }
    }
}
#endif
