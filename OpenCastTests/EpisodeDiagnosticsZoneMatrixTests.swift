import Foundation
import OpenCastPlayback
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode diagnostics zone matrix")
struct EpisodeDiagnosticsZoneMatrixTests {
    @Test("Tier classification splits exactly at the 0.8 confidence floor")
    func tierClassificationSplitsExactlyAtPointEight() throws {
        let document = makeDocument(spans: [
            span(id: 1, start: 10, end: 20, confidence: 0.8),
            span(id: 2, start: 30, end: 40, confidence: 0.7999),
        ])

        let matrix = EpisodeDiagnosticsZoneMatrix.make(
            document: document,
            bases: [basis("Unclamped", duration: nil)],
            installedAutoSkipZones: nil
        )

        let column = try #require(matrix.columns.first)
        #expect(column.spanOutcomes.map(\.isAutoSkip) == [true, false])
        #expect(column.autoSkipZones == [PlaybackSkipZone(id: 1, startTime: 10, endTime: 20)])
        #expect(column.displayOnlyZones == [PlaybackSkipZone(id: 2, startTime: 30, endTime: 40)])
    }

    @Test("Outro span is preserved, clamped, or dropped depending on the duration basis")
    func outroFateVariesAcrossDurations() throws {
        // The end-of-episode shape from real incidents: the outro span ends
        // slightly past some duration measurements.
        let outro = span(id: 1, start: 5_100, end: 5_195.276, confidence: 0.9)
        let document = makeDocument(spans: [outro])

        let matrix = EpisodeDiagnosticsZoneMatrix.make(
            document: document,
            bases: [
                basis("Local MP3", duration: 5_200),
                basis("Transcript", duration: 5_150),
                basis("RSS", duration: 5_100),
                basis("Unclamped", duration: nil),
            ],
            installedAutoSkipZones: nil
        )

        #expect(matrix.columns.allSatisfy { $0.spanOutcomes.count == 1 })
        let fates = matrix.columns.compactMap { $0.spanOutcomes.first?.fate }
        #expect(fates[0] == .preserved)
        #expect(fates[1] == .clamped(startTime: 5_100, endTime: 5_150))
        #expect(fates[2] == .dropped)
        #expect(fates[3] == .preserved)

        #expect(matrix.columns[2].autoSkipZones.isEmpty)
        #expect(matrix.columns[3].autoSkipZones == [
            PlaybackSkipZone(id: 1, startTime: 5_100, endTime: 5_195.276),
        ])
    }

    @Test("A merged span reports the zone that absorbed it")
    func mergedSpanReportsAbsorbingZone() throws {
        let document = makeDocument(spans: [
            span(id: 1, start: 10, end: 20, confidence: 0.9),
            span(id: 2, start: 20.5, end: 30, confidence: 0.9),
            span(id: 3, start: 50, end: 60, confidence: 0.9),
        ])

        let matrix = EpisodeDiagnosticsZoneMatrix.make(
            document: document,
            bases: [basis("RSS", duration: 100)],
            installedAutoSkipZones: nil
        )

        let column = try #require(matrix.columns.first)
        #expect(column.autoSkipZones == [
            PlaybackSkipZone(id: 1, startTime: 10, endTime: 30),
            PlaybackSkipZone(id: 3, startTime: 50, endTime: 60),
        ])
        #expect(column.spanOutcomes[0].mergedIntoZoneID == nil)
        #expect(column.spanOutcomes[1].mergedIntoZoneID == 1)
        #expect(column.spanOutcomes[1].fate == .preserved)
        #expect(column.spanOutcomes[2].mergedIntoZoneID == nil)
    }

    @Test("Installed comparison matches, mismatches, and is nil when nothing is installed")
    func installedComparisonStates() throws {
        let document = makeDocument(spans: [span(id: 1, start: 10, end: 20, confidence: 0.9)])
        let mappedZones = [PlaybackSkipZone(id: 1, startTime: 10, endTime: 20)]

        let matching = EpisodeDiagnosticsZoneMatrix.make(
            document: document,
            bases: [basis("RSS", duration: 100)],
            installedAutoSkipZones: mappedZones
        )
        #expect(try #require(matching.columns.first).matchesInstalledAutoSkipZones == true)

        let mismatching = EpisodeDiagnosticsZoneMatrix.make(
            document: document,
            bases: [basis("RSS", duration: 15)],
            installedAutoSkipZones: mappedZones
        )
        #expect(try #require(mismatching.columns.first).matchesInstalledAutoSkipZones == false)

        let uninstalled = EpisodeDiagnosticsZoneMatrix.make(
            document: document,
            bases: [basis("RSS", duration: 100)],
            installedAutoSkipZones: nil
        )
        #expect(try #require(uninstalled.columns.first).matchesInstalledAutoSkipZones == nil)
    }

    @Test("Display-only spans clamp within their own tier")
    func displayOnlySpansClampWithinTheirTier() throws {
        let document = makeDocument(spans: [
            span(id: 1, start: 90, end: 130, confidence: 0.5),
        ])

        let matrix = EpisodeDiagnosticsZoneMatrix.make(
            document: document,
            bases: [basis("RSS", duration: 100)],
            installedAutoSkipZones: []
        )

        let column = try #require(matrix.columns.first)
        let outcome = try #require(column.spanOutcomes.first)
        #expect(outcome.isAutoSkip == false)
        #expect(outcome.fate == .clamped(startTime: 90, endTime: 100))
        #expect(column.autoSkipZones.isEmpty)
        #expect(column.displayOnlyZones == [PlaybackSkipZone(id: 1, startTime: 90, endTime: 100)])
        // No auto-skip zones mapped and none installed: that is a match.
        #expect(column.matchesInstalledAutoSkipZones == true)
    }

    private func basis(_ label: String, duration: TimeInterval?) -> EpisodeDiagnosticsZoneMatrix.DurationBasis {
        EpisodeDiagnosticsZoneMatrix.DurationBasis(label: label, duration: duration)
    }

    private func makeDocument(spans: [EpisodeAdAnalysisSpan]) -> EpisodeAdAnalysisDocument {
        EpisodeAdAnalysisDocument(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            episodeID: "episode",
            podcastID: "podcast",
            requestID: "request",
            transcriptFingerprint: "fingerprint",
            transcriptUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            transcriptSegmentCount: 1,
            model: "gemini-test",
            policy: EpisodeAdAnalysisContract.expectedPolicy,
            spans: spans,
            warnings: [],
            usage: nil,
            createdAt: Date(timeIntervalSince1970: 1_780_000_001),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_002)
        )
    }

    private func span(
        id: Int,
        start: TimeInterval,
        end: TimeInterval,
        confidence: Double
    ) -> EpisodeAdAnalysisSpan {
        EpisodeAdAnalysisSpan(
            id: id,
            kind: .hostReadAd,
            label: "Span \(id)",
            startSegmentID: id,
            endSegmentID: id,
            startTime: start,
            endTime: end,
            confidence: confidence,
            evidenceQuote: "example"
        )
    }
}
