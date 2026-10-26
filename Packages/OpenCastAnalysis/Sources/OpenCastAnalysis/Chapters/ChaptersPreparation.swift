/// Which original segments one coalesced unit covers.
public struct ChaptersUnitRemap: Sendable, Hashable {
    public var originalStartID: Int64
    public var originalEndID: Int64
}

/// The model-facing view of a Chapters & Summary request.
public struct ChaptersPreparedRequest: Sendable, Hashable {
    public var modelRequest: TranscriptAnalysisRequest
    /// `nil` on the raw path. Otherwise model ids are zero-based unit
    /// indexes that must never escape a response.
    public var remap: [ChaptersUnitRemap]?
}

/// Deterministic segment coalescing for dense, long transcripts: the
/// model's id discipline degrades with the number of ids in the prompt, so
/// transcripts above the threshold are joined into units with a private
/// remap back to the original ids.
public enum ChaptersPreparation {
    public static let tooLong = "transcript_too_long"

    public static func prepare(
        _ original: TranscriptAnalysisRequest,
        policy: ChaptersSummaryPolicy
    ) -> Result<ChaptersPreparedRequest, AnalysisCodeError> {
        guard original.segments.count > policy.coalescing.aboveSegments else {
            return .success(ChaptersPreparedRequest(modelRequest: original, remap: nil))
        }
        let (units, remap) = coalesce(original.segments, policy: policy)
        guard units.count <= policy.coalescing.maxUnits else { return .failure(AnalysisCodeError(tooLong)) }
        var request = original
        request.segments = units
        request.transcript.segmentCount = units.count
        return .success(ChaptersPreparedRequest(modelRequest: request, remap: remap))
    }

    private struct OpenUnit {
        var segment: AnalysisSegment
        var joinedCharacters: Int
        var firstOriginalID: Int64
        var lastOriginalID: Int64
        var lastRawEnd: Double

        init(_ segment: AnalysisSegment) {
            self.segment = AnalysisSegment(id: 0, start: segment.start, end: segment.end, text: segment.text)
            joinedCharacters = RustText.charCount(segment.text)
            firstOriginalID = segment.id
            lastOriginalID = segment.id
            lastRawEnd = segment.end
        }

        func closes(before next: AnalysisSegment, policy: ChaptersSummaryPolicy) -> Bool {
            let spansMinimum = lastRawEnd - segment.start >= policy.coalescing.unitSeconds
            let wouldExceedJoinLimit = joinedCharacters + 1 + RustText.charCount(next.text) > policy.coalescing.unitChars
            let breaksOnGap = next.start - lastRawEnd > policy.coalescing.gapSeconds
            return spansMinimum || wouldExceedJoinLimit || breaksOnGap
        }

        mutating func extend(_ next: AnalysisSegment) {
            lastOriginalID = next.id
            lastRawEnd = next.end
            segment.end = next.end
            segment.text += " " + next.text
            joinedCharacters += 1 + RustText.charCount(next.text)
        }

        func close(unitID: Int) -> (AnalysisSegment, ChaptersUnitRemap) {
            var unit = segment
            unit.id = Int64(unitID)
            unit.end = rustMax(unit.end, unit.start)
            return (unit, ChaptersUnitRemap(originalStartID: firstOriginalID, originalEndID: lastOriginalID))
        }
    }

    /// Before adding each next segment, close the current unit when it
    /// already spans the minimum, joining would exceed the character limit,
    /// or the silence gap is too long.
    static func coalesce(
        _ segments: [AnalysisSegment],
        policy: ChaptersSummaryPolicy
    ) -> ([AnalysisSegment], [ChaptersUnitRemap]) {
        guard let first = segments.first else { return ([], []) }
        var units: [AnalysisSegment] = []
        var remap: [ChaptersUnitRemap] = []
        var current = OpenUnit(first)
        for segment in segments.dropFirst() {
            if current.closes(before: segment, policy: policy) {
                let (unit, entry) = current.close(unitID: units.count)
                units.append(unit)
                remap.append(entry)
                current = OpenUnit(segment)
            } else {
                current.extend(segment)
            }
        }
        let (unit, entry) = current.close(unitID: units.count)
        units.append(unit)
        remap.append(entry)
        return (units, remap)
    }
}
