import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript export builder")
struct TranscriptExportBuilderTests {
    @Test("Plain export joins segment texts line by line")
    func plainExportJoinsSegmentTextsLineByLine() {
        let text = TranscriptExportBuilder.plainText(from: [
            segment(id: 0, start: 0, text: "First line"),
            segment(id: 1, start: 65, text: "Second line")
        ])

        #expect(text == "First line\nSecond line")
    }

    @Test("Timestamped export prefixes each line with its start time")
    func timestampedExportPrefixesEachLineWithItsStartTime() {
        let text = TranscriptExportBuilder.timestampedText(from: [
            segment(id: 0, start: 0, text: "First line"),
            segment(id: 1, start: 65, text: "Second line"),
            segment(id: 2, start: 3_725, text: "Third line")
        ])

        #expect(text == "[0:00] First line\n[1:05] Second line\n[1:02:05] Third line")
    }

    @Test("Empty transcripts export as empty strings")
    func emptyTranscriptsExportAsEmptyStrings() {
        #expect(TranscriptExportBuilder.plainText(from: []) == "")
        #expect(TranscriptExportBuilder.timestampedText(from: []) == "")
    }

    private func segment(id: Int, start: TimeInterval, text: String) -> OpenCastTranscriptSegment {
        OpenCastTranscriptSegment(
            id: id,
            start: start,
            end: start + 5,
            text: text,
            avgLogProbability: -0.1,
            noSpeechProbability: 0.01
        )
    }
}
