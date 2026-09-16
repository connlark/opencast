import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript recap window builder")
struct TranscriptRecapWindowBuilderTests {
    private let fortyMinutes = TranscriptRecapTestFixtures.segments(count: 240)

    @Test("The last five minutes cover every segment overlapping the window")
    func lastFiveMinutes() async throws {
        let window = try await TranscriptRecapWindowBuilder.build(
            kind: .lastFiveMinutes,
            segments: fortyMinutes,
            playhead: 600,
            tokenCount: TranscriptRecapTestFixtures.tokenCount
        )
        let ids = try #require(window).segments.map(\.id)
        #expect(ids == Array(30...59))
        #expect(window?.startTime == 300)
        #expect(window?.endTime == 600)
        #expect(window?.isTruncated == false)
        #expect(window?.promptText.contains(TranscriptRecapWindowBuilder.gapMarker) == false)
        #expect(window?.promptText.hasPrefix("[#30 5:00] Segment 30") == true)
    }

    @Test("Below the minimum playhead there is nothing to recap")
    func minimumPlayhead() {
        #expect(TranscriptRecapWindowBuilder.candidateSegments(kind: .lastFiveMinutes, segments: fortyMinutes, playhead: 29) == nil)
        #expect(TranscriptRecapWindowBuilder.candidateSegments(kind: .lastFiveMinutes, segments: fortyMinutes, playhead: 30)?.map(\.id) == [0, 1, 2])
        #expect(TranscriptRecapWindowBuilder.candidateSegments(kind: .soFar, segments: fortyMinutes, playhead: 899) == nil)
        #expect(TranscriptRecapWindowBuilder.candidateSegments(kind: .soFar, segments: fortyMinutes, playhead: 900) != nil)
        #expect(TranscriptRecapWindowBuilder.candidateSegments(kind: .lastFiveMinutes, segments: [], playhead: 600) == nil)
    }

    @Test("A playhead past the transcript clamps to its end")
    func playheadPastEnd() async throws {
        let window = try #require(try await TranscriptRecapWindowBuilder.build(
            kind: .lastFiveMinutes,
            segments: fortyMinutes,
            playhead: 99_999,
            tokenCount: TranscriptRecapTestFixtures.tokenCount
        ))
        #expect(window.segments.map(\.id) == Array(210...239))
        #expect(window.playhead == 2_400)
        #expect(window.endTime == 2_400)
    }

    @Test("A short transcript at a later playhead is covered to its end")
    func shortTranscript() async throws {
        let short = TranscriptRecapTestFixtures.segments(count: 2, duration: 4.5)
        let window = try #require(try await TranscriptRecapWindowBuilder.build(
            kind: .lastFiveMinutes,
            segments: short,
            playhead: 90,
            tokenCount: TranscriptRecapTestFixtures.tokenCount
        ))
        #expect(window.segments.map(\.id) == [0, 1])
        #expect(window.endTime == 9)
    }

    @Test("So far keeps the recent fifteen minutes and samples a minute per earlier five")
    func soFarSampling() async throws {
        let window = try #require(try await TranscriptRecapWindowBuilder.build(
            kind: .soFar,
            segments: fortyMinutes,
            playhead: 1_200,
            tokenCount: TranscriptRecapTestFixtures.tokenCount
        ))
        let ids = window.segments.map(\.id)
        #expect(ids == Array(0...5) + Array(30...119))
        #expect(window.promptText.components(separatedBy: TranscriptRecapWindowBuilder.gapMarker).count == 2)

        let later = try #require(TranscriptRecapWindowBuilder.candidateSegments(kind: .soFar, segments: fortyMinutes, playhead: 2_400))
        // Recent 25:00–40:00 plus samples at 0, 5, 10, 15 and 20 minutes.
        #expect(later.map(\.id) == Array(0...5) + Array(30...35) + Array(60...65) + Array(90...95) + Array(120...125) + Array(150...239))
    }

    @Test("Over budget, the earliest segments go first and the window stays anchored at the playhead")
    func budgetTrimsFromTheFront() async throws {
        let wordy = TranscriptRecapTestFixtures.segments(count: 240, textLength: 400)
        var counts: [Int] = []
        let window = try #require(try await TranscriptRecapWindowBuilder.build(
            kind: .lastFiveMinutes,
            segments: wordy,
            playhead: 600,
            tokenBudget: 1_000
        ) { text in
            counts.append(text.count / 4)
            return text.count / 4
        })
        #expect(window.isTruncated)
        #expect(window.tokenCount <= 1_000)
        #expect(window.segments.last?.id == 59)
        #expect(window.segments.first!.id > 30)
        #expect(!window.segments.isEmpty)
        #expect(counts.first! > 1_000)
        #expect(counts.count <= 8)
    }

    @Test("So far trims its oldest samples before its recent minutes")
    func soFarTrimsSamplesFirst() async throws {
        let wordy = TranscriptRecapTestFixtures.segments(count: 240, textLength: 400)
        let window = try #require(try await TranscriptRecapWindowBuilder.build(
            kind: .soFar,
            segments: wordy,
            playhead: 1_200,
            tokenBudget: 1_000,
            tokenCount: TranscriptRecapTestFixtures.tokenCount
        ))
        #expect(window.isTruncated)
        #expect(window.segments.first!.id >= 30)
        #expect(window.segments.last?.id == 119)
    }

    @Test("Prompt lines carry the id and time, and a gap marker between non-adjacent runs")
    func promptFormatting() {
        let segments = TranscriptRecapTestFixtures.segments(count: 8)
        let text = TranscriptRecapWindowBuilder.promptText(for: [segments[1], segments[2], segments[6]])
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("[#1 0:10] "))
        #expect(lines[1].hasPrefix("[#2 0:20] "))
        #expect(lines[2] == TranscriptRecapWindowBuilder.gapMarker)
        #expect(lines[3].hasPrefix("[#6 1:00] "))
    }

    @Test("Menu state follows the playhead thresholds")
    func menuState() {
        #expect(TranscriptRecapMenuState.resolve(playhead: 29) == TranscriptRecapMenuState())
        #expect(TranscriptRecapMenuState.resolve(playhead: 30) == TranscriptRecapMenuState(canRecapLastFiveMinutes: true))
        #expect(TranscriptRecapMenuState.resolve(playhead: 900) == TranscriptRecapMenuState(canRecapLastFiveMinutes: true, showsRecapSoFar: true))
    }
}
