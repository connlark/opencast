/// One rule a Chapters & Summary answer broke badly enough to reject it.
public struct ChaptersHardViolation: Sendable, Hashable {
    public var rule: String
    public var detail: String
}

/// Every hard violation of a rejected answer, in the order found.
public struct ChaptersRejection: Error, Sendable, Hashable {
    public var violations: [ChaptersHardViolation]

    /// The rule codes, comma-joined, as reported to the app.
    public var codes: String { violations.map(\.rule).joined(separator: ",") }
}

/// A validated Chapters & Summary answer.
public struct ChaptersValidatedAnalysis: Sendable, Hashable {
    public var chapters: [TranscriptAnalysisChapter]
    public var summary: TranscriptAnalysisSummary
    public var warnings: [String]
}

/// The Chapters & Summary validator. Hard violations reject the whole answer
/// (chapters are a partition: one bad chapter invalidates the navigation);
/// soft violations become warnings and never fail a run.
public enum ChaptersValidator {
    static let titleMaxCharacters = 60
    static let titleMaxWords = 12
    static let summaryMaxCharacters = 1_200
    static let oneLineMaxCharacters = 140
    static let claimTextMaxCharacters = 220
    static let minimumClaims = 1
    static let maximumClaims = 12

    /// The chapter ceiling: one per `secondsPerChapter` of audio, at least
    /// the minimum.
    public static func maxChapters(durationSeconds: Double, policy: ChaptersSummaryPolicy) -> Int {
        max(policy.chapterCap.min, saturatingCount(rustCeil(durationSeconds / policy.chapterCap.secondsPerChapter)))
    }

    /// A raw request validates once. A coalesced request must first pass in
    /// unit space; only then are ids mapped back and the whole contract run
    /// again against the original segments, so no unit id can escape.
    public static func validateAndRemap(
        original: TranscriptAnalysisRequest,
        prepared: ChaptersPreparedRequest,
        output: ChaptersModelOutput,
        policy: ChaptersSummaryPolicy
    ) -> Result<ChaptersValidatedAnalysis, ChaptersRejection> {
        guard let remap = prepared.remap else {
            return validate(original, output, policy: policy)
        }
        if case .failure(let violations) = validate(prepared.modelRequest, output, policy: policy) {
            return .failure(violations)
        }
        guard let mapped = remapOutput(output, remap) else {
            return .failure(ChaptersRejection(violations: [ChaptersHardViolation(
                rule: "id_discipline",
                detail: "validated unit id could not be remapped"
            )]))
        }
        return validate(original, mapped, policy: policy)
    }

    static func remapOutput(_ output: ChaptersModelOutput, _ remap: [ChaptersUnitRemap]) -> ChaptersModelOutput? {
        func entry(_ id: Int64) -> ChaptersUnitRemap? {
            guard id >= 0, id < Int64(remap.count) else { return nil }
            return remap[Int(id)]
        }
        var chapters: [ChaptersModelOutput.Chapter] = []
        for chapter in output.chapters {
            guard let start = entry(chapter.startSegmentID), let end = entry(chapter.endSegmentID) else { return nil }
            chapters.append(.init(
                title: chapter.title,
                startSegmentID: start.originalStartID,
                endSegmentID: end.originalEndID,
                confidence: chapter.confidence
            ))
        }
        var claims: [ChaptersModelOutput.Claim] = []
        for claim in output.summary.claims {
            guard let evidence = entry(claim.evidenceSegmentID) else { return nil }
            claims.append(.init(text: claim.text, evidenceSegmentID: evidence.originalStartID))
        }
        return ChaptersModelOutput(
            chapters: chapters,
            summary: .init(
                summary: output.summary.summary,
                oneLineDescription: output.summary.oneLineDescription,
                claims: claims
            )
        )
    }

    public static func validate(
        _ request: TranscriptAnalysisRequest,
        _ output: ChaptersModelOutput,
        policy: ChaptersSummaryPolicy
    ) -> Result<ChaptersValidatedAnalysis, ChaptersRejection> {
        var hard: [ChaptersHardViolation] = []
        var warnings: [String] = []
        func violation(_ rule: String, _ detail: String) {
            hard.append(ChaptersHardViolation(rule: rule, detail: detail))
        }
        let segments = request.segments
        var indexByID: [Int64: Int] = [:]
        for (index, segment) in segments.enumerated() { indexByID[segment.id] = index }
        let lastIndex = segments.count - 1

        if output.chapters.isEmpty {
            violation("chapters_shape", "chapters empty")
        }
        let cap = maxChapters(durationSeconds: request.transcript.audioDuration, policy: policy)
        if output.chapters.count > cap {
            violation(
                "chapter_count_cap",
                "\(output.chapters.count) chapters exceeds cap \(cap) for \(RustFloatFormat.fixed(request.transcript.audioDuration, places: 0))s"
            )
        }

        var chapters: [TranscriptAnalysisChapter] = []
        var previousEndIndex: Int?
        for (index, chapter) in output.chapters.enumerated() {
            let startIndex = indexByID[chapter.startSegmentID]
            let endIndex = indexByID[chapter.endSegmentID]
            if startIndex == nil {
                violation("id_discipline", "chapter \(index) start_segment_id \(chapter.startSegmentID) is not a submitted id")
            }
            if endIndex == nil {
                violation("id_discipline", "chapter \(index) end_segment_id \(chapter.endSegmentID) is not a submitted id")
            }
            if let startIndex, let endIndex {
                if endIndex < startIndex {
                    violation("chapter_order", "chapter \(index) ends before it starts")
                } else {
                    if let previous = previousEndIndex {
                        if startIndex <= previous {
                            violation(
                                "chapter_overlap",
                                "chapter \(index) starts at segment \(chapter.startSegmentID), chapter \(index - 1) ended at segment \(segments[previous].id)"
                            )
                        } else if startIndex != previous + 1 {
                            warnings.append("coverage_gap: gap of \(startIndex - previous - 1) segments before chapter \(index)")
                        }
                    } else if startIndex != 0 {
                        warnings.append("coverage_gap: first chapter starts at segment \(chapter.startSegmentID), not \(segments[0].id)")
                    }
                    previousEndIndex = endIndex
                }
            }

            if RustText.isBlank(chapter.title) {
                violation("chapter_title", "chapter \(index) title missing or empty")
            } else {
                let titleCharacters = RustText.charCount(chapter.title)
                if titleCharacters > titleMaxCharacters {
                    warnings.append("chapter_title_length: chapter \(index) title is \(titleCharacters) chars")
                }
                let wordCount = RustText.whitespaceWordCount(chapter.title)
                if wordCount > titleMaxWords {
                    warnings.append("chapter_title_words: chapter \(index) title is \(wordCount) words")
                }
                checkFreeText(chapter.title, field: "chapter \(index) title", hard: &hard, warnings: &warnings)
            }
            if !chapter.confidence.isFinite || !(0.0...1.0).contains(chapter.confidence) {
                violation("chapter_confidence", "chapter \(index) confidence \(RustFloatFormat.display(chapter.confidence))")
            }

            if let startIndex, let endIndex, endIndex >= startIndex {
                chapters.append(TranscriptAnalysisChapter(
                    title: RustText.trim(chapter.title),
                    startSegmentID: chapter.startSegmentID,
                    endSegmentID: chapter.endSegmentID,
                    startTime: segments[startIndex].start,
                    endTime: segments[endIndex].end,
                    confidence: chapter.confidence
                ))
            }
        }
        if let previous = previousEndIndex, previous != lastIndex {
            warnings.append("coverage_gap: last chapter ends at segment \(segments[previous].id), transcript ends at segment \(segments[lastIndex].id)")
        }

        let summary = output.summary
        if RustText.isBlank(summary.summary) {
            violation("summary_text", "summary missing or empty")
        } else {
            let characters = RustText.charCount(summary.summary)
            if characters > summaryMaxCharacters {
                violation("summary_length", "summary is \(characters) chars")
            }
            checkFreeText(summary.summary, field: "summary", hard: &hard, warnings: &warnings)
        }
        if RustText.isBlank(summary.oneLineDescription) {
            violation("one_line_text", "one_line_description missing or empty")
        } else {
            let characters = RustText.charCount(summary.oneLineDescription)
            if characters > oneLineMaxCharacters {
                violation("one_line_length", "one_line_description is \(characters) chars")
            }
            checkFreeText(summary.oneLineDescription, field: "one_line_description", hard: &hard, warnings: &warnings)
        }
        if !(minimumClaims...maximumClaims).contains(summary.claims.count) {
            violation("claims_count", "claims count \(summary.claims.count)")
        } else {
            for (index, claim) in summary.claims.enumerated() {
                if indexByID[claim.evidenceSegmentID] == nil {
                    violation("id_discipline", "claim \(index) evidence_segment_id \(claim.evidenceSegmentID) is not a submitted id")
                }
                if RustText.isBlank(claim.text) {
                    violation("claim_text", "claim \(index) text missing or empty")
                } else {
                    let characters = RustText.charCount(claim.text)
                    if characters > claimTextMaxCharacters {
                        warnings.append("claim_text_length: claim \(index) text is \(characters) chars")
                    }
                    checkFreeText(claim.text, field: "claim \(index) text", hard: &hard, warnings: &warnings)
                }
            }
        }

        if !hard.isEmpty { return .failure(ChaptersRejection(violations: hard)) }
        return .success(ChaptersValidatedAnalysis(
            chapters: chapters,
            summary: TranscriptAnalysisSummary(
                summary: RustText.trim(summary.summary),
                oneLineDescription: RustText.trim(summary.oneLineDescription),
                claims: summary.claims.map {
                    TranscriptAnalysisClaim(text: RustText.trim($0.text), evidenceSegmentID: $0.evidenceSegmentID)
                }
            ),
            warnings: warnings
        ))
    }

    static func checkFreeText(
        _ text: String,
        field: String,
        hard: inout [ChaptersHardViolation],
        warnings: inout [String]
    ) {
        if containsURLShape(text) {
            hard.append(ChaptersHardViolation(rule: "no_urls", detail: "\(field) contains a URL-shaped string"))
        }
        if containsEmoji(text) {
            warnings.append("no_emoji: \(field) contains emoji")
        }
        if containsHashtag(text) {
            warnings.append("no_hashtags: \(field) contains a hashtag")
        }
        if text.unicodeScalars.contains("\n") {
            warnings.append("no_newlines: \(field) contains a newline")
        }
    }

    /// Scheme prefixes, `www.`, or a bare `label.tld/` where the character
    /// before the dot is an ASCII letter, digit or hyphen.
    static func containsURLShape(_ text: String) -> Bool {
        let lower = Array(text.lowercased().utf8)
        for marker in ["http://", "https://", "www."] where !lower.byteOccurrences(of: Array(marker.utf8)).isEmpty {
            return true
        }
        for suffix in [".com/", ".net/", ".org/", ".io/", ".co/", ".ly/", ".gg/"] {
            for position in lower.byteOccurrences(of: Array(suffix.utf8)) where position > 0 {
                let before = lower[position - 1]
                let isASCIIAlphanumeric = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(before)
                    || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(before)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(before)
                if isASCIIAlphanumeric || before == UInt8(ascii: "-") { return true }
            }
        }
        return false
    }

    static func containsEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x1F000...0x1FAFF).contains(scalar.value)
                || (0x2700...0x27BF).contains(scalar.value)
                || (0x2600...0x26FF).contains(scalar.value)
        }
    }

    static func containsHashtag(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "#" && index + 1 < scalars.count {
            let next = scalars[index + 1]
            if RustText.isAlphanumeric(next) || next == "_" { return true }
        }
        return false
    }

    /// Rust `f64::ceil`.
    static func rustCeil(_ value: Double) -> Double { value.rounded(.up) }

    /// Rust's saturating `f64 as usize` (NaN and negatives are 0).
    static func saturatingCount(_ value: Double) -> Int {
        if value.isNaN || value <= 0 { return 0 }
        if value >= Double(Int.max) { return Int.max }
        return Int(value)
    }
}

extension Array where Element == UInt8 {
    func byteOccurrences(of needle: [UInt8]) -> [Int] {
        guard !needle.isEmpty, needle.count <= count else { return [] }
        return (0...(count - needle.count)).filter { start in
            self[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}
