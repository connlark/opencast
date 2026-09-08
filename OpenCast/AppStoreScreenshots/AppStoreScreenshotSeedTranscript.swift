#if DEBUG
import Foundation
import OpenCastTranscription
import SwiftData

/// Seeds a completed transcript and ad analysis for the primary Orbit Report
/// episode so the App Store set can show the ad-marked timeline, the badged
/// transcript, and the completed Sound Lab state from records alone.
enum AppStoreScreenshotSeedTranscript {
    /// All span times sit inside the 300s seed WAV: the Now Playing slider
    /// tracks the real AVPlayer item duration, not the episode metadata.
    private static let audioDuration: TimeInterval = 300

    @discardableResult
    static func seed(
        in context: ModelContext,
        audioURL: String,
        sourceFileSHA256 sourceSHA: String,
        sourceFileByteCount: Int64,
        createdAt: Date
    ) throws -> EpisodeTranscriptDocument {
        let episodeID = AppStoreScreenshotSeedCatalog.primaryEpisodeID
        let podcastID = AppStoreScreenshotSeedCatalog.primaryFeedURL
        let modelSummary = OpenCastWhisperModelInstalledSummary(
            modelIdentifier: OpenCastWhisperModel.largeV3.rawValue,
            version: OpenCastWhisperModel.largeV3.defaultRemoteVersion,
            totalByteCount: 629_482_970,
            treeSHA256: "20a910bd8ea9f94a3e4438780f6e2f0aa3bbcd3fc1f8e99fccb2d64b68935603"
        )

        let transcriptFileStore = EpisodeTranscriptFileStore()
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
            sourceFileByteCount: sourceFileByteCount,
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
            sourceFileByteCount: sourceFileByteCount,
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

        return transcriptDocument
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
                evidenceQuote: "our friends over at Urban Frequency"
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

    // The word "light" appears only here (segments 9 and 18), never in the
    // episode's title, summary, or show notes, so the search shot's hit for
    // this episode comes with a transcript snippet.
    private static func transcriptSegments() -> [OpenCastTranscriptSegment] {
        let lines: [(start: TimeInterval, end: TimeInterval, text: String)] = [
            (0, 7, "It's four in the morning on a mountain in the desert, the dome is open, and a mirror the size of a swimming pool is about to open its eye for the first time."),
            (7, 14, "This week: first light. What a brand-new telescope actually sees on night one, and why nobody in the control room was looking at the pretty picture."),
            (14, 21, "Because the first image is never the point. The first image is a test. The point is the smudge in the corner that shouldn't have been there."),
            (21, 28, "I'm Dana Whitlock, this is Orbit Report, and I stayed up for eleven of those nights. Here's what the new telescope saw first."),
            (28, 34, "This episode is brought to you by Bottomless Mug Coffee Co. — the coffee subscription that notices when you're awake at 3 a.m. and ships accordingly."),
            (34, 40, "Their roasters watch your actual consumption, so the next bag lands the same morning the last one runs out."),
            (40, 46, "I've been on their Night Shift blend all observing season. It tastes like a clear forecast."),
            (46, 52, "Every bag comes with a no-questions refund, even if your only question is how it got to your door that fast."),
            (52, 58, "Go to bottomlessmug dot coffee and use code ORBIT for a free first bag. That's code ORBIT. Now — back to the dome."),
            (58, 66, "So. First light is what astronomers call the first real image a new telescope takes. It's a milestone, and it's also a little bit of theater."),
            (66, 74, "The mirror had been polished for six years. The camera had been tested in a vacuum chamber. Everyone knew it would work. Everyone was still terrified."),
            (74, 82, "They pointed it at a boring patch of sky on purpose. No famous galaxy, no nebula. Just a field of ordinary stars they could compare to old surveys."),
            (82, 90, "The first exposure came back at 3:12 in the morning. Sharp stars, clean corners, no obvious mess. Somebody clapped. Somebody else said \"wait.\""),
            (90, 98, "Here's where the night got interesting. In the lower left of the frame there was a faint streak — not a star, not a satellite, not a cosmic ray."),
            (98, 106, "A streak means something moved during the exposure. Satellites move fast and leave long, bright lines. This one was short and dim."),
            (106, 114, "Short and dim means far away and slow. That narrows it down to a rock — an asteroid or a comet — that nobody had catalogued yet."),
            (114, 123, "So on the very first night, before the press release, before the pretty picture, the new telescope had already found something nobody had seen."),
            (123, 132, "I want to pause on that, because what makes a big mirror useful isn't the size. It's how much sky it can check, over and over, for things that change."),
            (132, 141, "Speaking of things that change — our friends over at Urban Frequency just did a whole episode on light pollution maps, and it pairs weirdly well with this one."),
            (141, 150, "If you like the parts of this show where I complain about sodium streetlights, their back catalog is basically that, with better maps."),
            (150, 158, "Alright. Where were we. Right — a short, dim streak, and a control room full of people who suddenly weren't tired anymore."),
            (158, 168, "They took a second exposure. Then a third. The streak moved between frames exactly the way a slow rock would, and it sat on the ecliptic — the plane where most of them live."),
            (168, 177, "By sunrise they had three positions and a rough orbit. Not a great orbit — three points is barely a curve — but enough to know it wasn't going to hit anything."),
            (177, 186, "And here's the part I love: the observatory's follow-up plan for a night-one discovery didn't exist. Nobody had written it. They improvised it over bad coffee."),
            (186, 196, "Two days later a smaller telescope on another continent recovered the object, the orbit tightened up, and it got a provisional designation — letters and numbers, no name."),
            (196, 205, "So the first thing the new telescope saw was a rock about the size of a stadium, roughly the distance of Mars, minding its own business. That's the whole story."),
            (205, 212, "We'll get to what happened to the pretty picture in a second — first, a quick break."),
            (212, 219, "This show is supported by Northlight Optics, the small binocular company that thinks \"good enough for the moon\" is a low bar."),
            (219, 226, "Their eight-by-forty-twos are the pair I keep on the windowsill, and the pair I hand to anyone who says you can't see anything from a city."),
            (226, 232, "Start with the moon at northlight dot optics slash orbit, and use code ORBIT for free shipping."),
            (232, 239, "Okay. The pretty picture. It went out a week later, and it was a famous galaxy after all, because press releases want a galaxy."),
            (239, 246, "But the astronomers I talked to kept bringing up the streak, not the galaxy. The galaxy proved the mirror worked. The streak proved the survey would."),
            (246, 253, "Over the next ten years this telescope will image the whole southern sky every few nights and flag everything that moves or blinks."),
            (253, 260, "Millions of alerts a night, most of them boring, some of them rocks, and every so often something that makes a control room go quiet."),
            (260, 266, "The real lesson isn't \"big mirrors are good.\" It's that the sky is full of things that only show up if you keep looking at the same place."),
            (266, 272, "So that's first light: a boring field, a faint streak, and a rock with a serial number for a name. Not a bad opening night."),
            (272, 280, "If this episode kept you up past bedtime, the best thank-you is a review — it genuinely helps other night owls find the show."),
            (280, 288, "Members get ad-free episodes and the annotated first-light frames from tonight's story at orbitreport dot fm slash support."),
            (288, 296, "Members also get the extended cut of next week's episode early: why every comet is a surprise."),
            (296, 300, "I'm Dana Whitlock. This was Orbit Report. Get some sleep.")
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
