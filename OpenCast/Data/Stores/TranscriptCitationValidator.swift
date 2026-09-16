import Foundation

/// Maps citations back to what the model was shown. For a recap that is the
/// window; for an answer it is exactly the segment lines the tool outputs
/// carried this turn. An id never shown, a blank bullet, or a repeat of an
/// earlier bullet (the model pads short windows with the same sentence) is
/// dropped rather than rendered.
nonisolated enum TranscriptCitationValidator {
    static func validate(_ recap: TranscriptRecap, window: TranscriptRecapWindow) -> TranscriptRecapValidation {
        let startByID = Dictionary(window.segments.map { ($0.id, $0.start) }, uniquingKeysWith: { first, _ in first })
        var bullets: [TranscriptRecapResultBullet] = []
        var dropped: [TranscriptRecapBullet] = []
        var seenTexts: Set<String> = []
        for bullet in recap.bullets {
            let text = bullet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  seenTexts.insert(text.lowercased()).inserted,
                  let start = startByID[bullet.segmentID]
            else {
                dropped.append(bullet)
                continue
            }
            bullets.append(TranscriptRecapResultBullet(text: text, segmentID: bullet.segmentID, start: start))
        }
        return TranscriptRecapValidation(bullets: bullets, droppedBullets: dropped)
    }

    static func validate(
        _ answer: TranscriptAnswer,
        toolExchanges: [TranscriptIntelligenceToolExchange],
        document: EpisodeTranscriptDocument
    ) -> TranscriptAskValidation {
        validate(answer, shownSegmentIDs: shownSegmentIDs(in: toolExchanges), document: document)
    }

    static func validate(
        _ answer: TranscriptAnswer,
        shownSegmentIDs: Set<Int>,
        document: EpisodeTranscriptDocument
    ) -> TranscriptAskValidation {
        let startByID = Dictionary(document.segments.map { ($0.id, $0.start) }, uniquingKeysWith: { first, _ in first })
        var citations: [TranscriptAskCitation] = []
        var dropped: [Int] = []
        var seen: Set<Int> = []
        for id in answer.citations {
            guard seen.insert(id).inserted else {
                continue
            }
            guard shownSegmentIDs.contains(id), let start = startByID[id] else {
                dropped.append(id)
                continue
            }
            citations.append(TranscriptAskCitation(segmentID: id, start: start))
        }
        return TranscriptAskValidation(citations: citations, droppedCitationIDs: dropped)
    }

    /// Every segment id the tool outputs printed this turn.
    static func shownSegmentIDs(in exchanges: [TranscriptIntelligenceToolExchange]) -> Set<Int> {
        var ids: Set<Int> = []
        for exchange in exchanges {
            guard let output = exchange.output else {
                continue
            }
            ids.formUnion(TranscriptToolOutput.segmentIDs(in: output))
        }
        return ids
    }
}
