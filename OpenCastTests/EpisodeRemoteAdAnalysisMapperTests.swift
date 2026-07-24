import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
@Suite("Remote ad analysis mapper")
struct EpisodeRemoteAdAnalysisMapperTests {
    @Test("A valid cloud analysis maps to a current persisted document")
    func validAnalysisMaps() throws {
        let transcript = makeTranscript()
        let document = try EpisodeRemoteAdAnalysisMapper.document(
            from: makeSuccess(),
            transcript: transcript,
            requestID: "job-cloud-1"
        )

        #expect(document.episodeID == transcript.episodeID)
        #expect(document.podcastID == transcript.podcastID)
        #expect(document.requestID == "job-cloud-1")
        #expect(document.policy == EpisodeAdAnalysisContract.expectedPolicy)
        #expect(document.model == "gemini-3.5-flash")
        #expect(document.spans.count == 1)
        #expect(document.spans[0].kind == .hostReadAd)
        #expect(document.spans[0].id == 0)
        #expect(document.spans[0].confidence == 1.0)

        // The locally computed fingerprint must satisfy the exact currency
        // check the zones/skip pipeline runs.
        let store = EpisodeAdAnalysisStore()
        #expect(store.isCurrentAnalysisDocument(document, for: transcript))
    }

    @Test("A cloud analysis stays current after the transcript's disk round trip")
    func analysisStaysCurrentAfterTranscriptDiskRoundTrip() throws {
        // The in-memory transcript carries a sub-second `updatedAt`; the
        // `.iso8601` disk coding drops the fraction, so the reloaded
        // transcript the freshness checks see is truncated.
        let transcript = makeTranscript()
        let document = try EpisodeRemoteAdAnalysisMapper.document(
            from: makeSuccess(),
            transcript: transcript,
            requestID: "job-cloud-1"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reloadedTranscript = try decoder.decode(
            EpisodeTranscriptDocument.self,
            from: encoder.encode(transcript)
        )

        let store = EpisodeAdAnalysisStore()
        #expect(store.isCurrentAnalysisDocument(document, for: reloadedTranscript))
    }

    @Test("Policy drift throws so the pass falls back to device analysis")
    func policyDriftThrows() {
        var success = makeSuccess()
        success.policy = "promo_ad_breaks_v3"
        #expect(throws: EpisodeRemoteAdAnalysisMapper.ValidationError.self) {
            try EpisodeRemoteAdAnalysisMapper.document(
                from: success,
                transcript: makeTranscript(),
                requestID: "job-cloud-1"
            )
        }
    }

    @Test("An unknown span kind throws — never skippable audio")
    func unknownKindThrows() {
        var success = makeSuccess()
        success.spans[0].kind = "subliminal_ad"
        #expect(throws: EpisodeRemoteAdAnalysisMapper.ValidationError.self) {
            try EpisodeRemoteAdAnalysisMapper.document(
                from: success,
                transcript: makeTranscript(),
                requestID: "job-cloud-1"
            )
        }
    }

    @Test("Broken timings and out-of-range segment ids throw")
    func timingAndSegmentValidation() {
        var pastEnd = makeSuccess()
        pastEnd.spans[0].endTime = 200
        #expect(throws: EpisodeRemoteAdAnalysisMapper.ValidationError.self) {
            try EpisodeRemoteAdAnalysisMapper.document(
                from: pastEnd,
                transcript: makeTranscript(),
                requestID: "job-cloud-1"
            )
        }

        var badIDs = makeSuccess()
        badIDs.spans[0].endSegmentID = 99
        #expect(throws: EpisodeRemoteAdAnalysisMapper.ValidationError.self) {
            try EpisodeRemoteAdAnalysisMapper.document(
                from: badIDs,
                transcript: makeTranscript(),
                requestID: "job-cloud-1"
            )
        }

        var reversed = makeSuccess()
        reversed.spans[0].endTime = reversed.spans[0].startTime
        #expect(throws: EpisodeRemoteAdAnalysisMapper.ValidationError.self) {
            try EpisodeRemoteAdAnalysisMapper.document(
                from: reversed,
                transcript: makeTranscript(),
                requestID: "job-cloud-1"
            )
        }
    }

    private func makeSuccess() -> OpenCastRemoteTranscriptionAdAnalysisSuccess {
        OpenCastRemoteTranscriptionAdAnalysisSuccess(
            model: "gemini-3.5-flash",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: [OpenCastRemoteTranscriptionAdAnalysisSpan(
                kind: "host_read_ad",
                label: "Sponsor",
                startSegmentID: 0,
                endSegmentID: 1,
                startTime: 0,
                endTime: 12,
                confidence: 1.4,
                evidenceQuote: "brought to you by"
            )],
            warnings: []
        )
    }

    private func makeTranscript() -> EpisodeTranscriptDocument {
        let segments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: 0,
                end: 8,
                text: "brought to you by sponsor",
                avgLogProbability: -0.2,
                noSpeechProbability: 0.1
            ),
            OpenCastTranscriptSegment(
                id: 1,
                start: 8,
                end: 16,
                text: "back to the show",
                avgLogProbability: -0.2,
                noSpeechProbability: 0.1
            ),
        ]
        return EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: "ep-cloud-1",
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/ep-cloud-1.mp3",
            sourceFileByteCount: 987_654_321,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "@cf/openai/whisper-large-v3-turbo",
            modelVersion: "v1",
            modelTreeSHA256: "tree-sha",
            languageCode: "en",
            audioDuration: 16,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: .now.addingTimeInterval(-10),
            updatedAt: .now
        )
    }
}
