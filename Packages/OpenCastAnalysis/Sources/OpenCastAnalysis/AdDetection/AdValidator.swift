/// The result of validating one answer: the breaks that passed, machine
/// issues (ids only, safe to log) and notices for conservative boundary
/// changes that are not discarded candidates.
public struct AdValidation: Sendable, Hashable {
    public var spans: [AdAnalysisSpan] = []
    public var issues: [String] = []
    public var notices: [String] = []

    public var isComplete: Bool { issues.isEmpty }

    public init(spans: [AdAnalysisSpan] = [], issues: [String] = [], notices: [String] = []) {
        self.spans = spans
        self.issues = issues
        self.notices = notices
    }
}

/// The ad-break validator. Boundary receipts are checked at both submitted
/// boundaries; an interior promotional quote is never permission to accept
/// a whole span. Any issue fails the scope closed.
public enum AdValidator {
    /// Short mixed boundary segments are included whole up to this length;
    /// longer ones are trimmed inward.
    static let maxMixedBoundarySeconds = 10.0
    /// A single break may not cover more than this share of the request.
    static let maxRequestCoverage = 0.8
    /// Receipts longer than this many UTF-8 bytes are never located.
    static let maxQuoteBytes = 2048
    /// A declared runtime shorter than this share of the audio earns no
    /// extra budget.
    static let declaredDurationMinimumFraction = 0.5

    /// Validates an answer against the whole request, with the global
    /// coverage and budget alarms.
    public static func validate(_ request: AdAnalysisRequest, _ output: AdModelOutput, policy: AdDetectionPolicy) -> AdValidation {
        validateScope(request, output, entireRequest: true, policy: policy)
    }

    /// Validates one window's answer, without the global alarms.
    public static func validateWindow(_ request: AdAnalysisRequest, _ output: AdModelOutput, policy: AdDetectionPolicy) -> AdValidation {
        validateScope(request, output, entireRequest: false, policy: policy)
    }

    /// The episode ad budget in seconds: `max(fraction × runtime, floor)`,
    /// plus the excess of the served audio over a plausible declared runtime
    /// (dynamically inserted advertising by construction).
    public static func episodeAdBudgetSeconds(_ transcript: AdAnalysisTranscript, policy: AdDetectionPolicy) -> Double {
        let audio = transcript.audioDuration
        func base(_ runtime: Double) -> Double {
            rustMax(policy.limits.budgetFraction * runtime, policy.limits.budgetFloorSeconds)
        }
        if let declared = transcript.declaredDuration,
           declared.isFinite, audio.isFinite,
           declared < audio, declared >= declaredDurationMinimumFraction * audio {
            return base(declared) + (audio - declared)
        }
        return base(audio)
    }

    static func validateScope(
        _ request: AdAnalysisRequest,
        _ output: AdModelOutput,
        entireRequest: Bool,
        policy: AdDetectionPolicy
    ) -> AdValidation {
        var result = AdValidation()
        let segments = request.segments
        // The configured ceiling may only tighten the services' own, which
        // counts windows in their fixed 800/120 geometry: smaller configured
        // windows must not buy an episode more spans.
        let configuredCap = policy.limits.spansPerWindow
            * (entireRequest ? AdWindowing.windowCount(segmentCount: segments.count, policy: policy) : 1)
        let serviceCap = AdPipelineConstants.serviceSpansPerWindow
            * (entireRequest
                ? AdWindowing.windowCount(
                    segmentCount: segments.count,
                    windowSegments: AdPipelineConstants.serviceWindowSegments,
                    overlapSegments: AdPipelineConstants.serviceWindowOverlapSegments
                )
                : 1)
        if output.spans.count > min(configuredCap, serviceCap) {
            result.issues.append("v3_too_many_breaks")
            return result
        }
        let positions = segmentPositions(request)
        for span in output.spans {
            let tag = "\(span.startSegmentID)-\(span.endSegmentID)"
            guard let kind = AdSpanKind.allCases.first(where: { RustText.same(span.kind, $0.rawValue) }) else {
                result.issues.append("v3_invalid_kind:\(tag)")
                continue
            }
            guard let start = positions[span.startSegmentID], let end = positions[span.endSegmentID] else {
                result.issues.append("v3_unknown_boundary:\(tag)")
                continue
            }
            if end < start
                || !span.confidence.isFinite
                || !(0.0...1.0).contains(span.confidence)
                || RustText.isBlank(span.label)
                || span.label.utf8.count > 256 {
                result.issues.append("v3_invalid_span:\(tag)")
                continue
            }
            let startReceipt = receiptPosition(segments[start].text, span.startQuote, policy: policy)
            let endReceipt = receiptPosition(segments[end].text, span.endQuote, policy: policy)
            guard let startReceipt, let endReceipt else {
                result.issues.append("v3_boundary_receipt_mismatch:\(tag)")
                continue
            }
            let cue = RustText.normalizedReceiptTokens(span.evidenceQuote)
            let content = RustText.normalizedReceiptTokens(joinedText(segments[start...end]))
            if cue.count < 2 || cue.count > policy.limits.evidenceWords || !content.containsRun(cue) {
                result.issues.append("v3_evidence_mismatch:\(tag)")
                continue
            }
            func shortBoundary(_ index: Int) -> Bool {
                let duration = segments[index].end - segments[index].start
                return duration.isFinite && duration > 0 && duration <= maxMixedBoundarySeconds
            }
            let mixedStart = startReceipt.start > 0
            let mixedEnd = endReceipt.end < endReceipt.total
            let safeStart = start + (mixedStart && !shortBoundary(start) ? 1 : 0)
            let endTrim = mixedEnd && !shortBoundary(end) ? 1 : 0
            guard end >= endTrim else {
                result.issues.append("v3_mixed_boundary_unresolvable:\(tag)")
                continue
            }
            let safeEnd = end - endTrim
            if safeStart > safeEnd {
                result.issues.append("v3_mixed_boundary_unresolvable:\(tag)")
                continue
            }
            if safeStart != start || safeEnd != end {
                result.notices.append("v3_boundary_trimmed:\(tag)->\(segments[safeStart].id)-\(segments[safeEnd].id)")
            }
            if (mixedStart && safeStart == start) || (mixedEnd && safeEnd == end) {
                result.notices.append("v3_short_mixed_boundary_included:\(tag)")
            }
            let first = segments[safeStart]
            let last = segments[safeEnd]
            if last.end <= first.start || last.end - first.start > policy.limits.maxBreakSeconds {
                result.issues.append("v3_break_duration:\(tag)")
                continue
            }
            if entireRequest && Double(safeEnd - safeStart + 1) > Double(segments.count) * maxRequestCoverage {
                result.issues.append("v3_covers_request:\(tag)")
                continue
            }
            result.spans.append(AdAnalysisSpan(
                kind: kind,
                label: RustText.trim(span.label),
                startSegmentID: first.id,
                endSegmentID: last.id,
                startTime: first.start,
                endTime: last.end,
                confidence: span.confidence,
                evidenceQuote: RustText.trim(span.evidenceQuote),
                startBoundary: AdBoundary(segmentID: span.startSegmentID, quote: span.startQuote),
                endBoundary: AdBoundary(segmentID: span.endSegmentID, quote: span.endQuote)
            ))
        }
        result.spans = sortedByTime(result.spans)
        // Reconcile overlapping windows only across overlapping or truly
        // adjacent submitted segments, never across a segment of unclassified
        // show content, and merge the two confidence tiers independently.
        var tiers: [[AdAnalysisSpan]] = [[], []]
        for span in result.spans {
            let tier = span.confidence >= 0.8 ? 1 : 0
            if var last = tiers[tier].last {
                let adjacent = positions[span.startSegmentID]! <= positions[last.endSegmentID]! + 1
                    && span.startTime - last.endTime <= 1.0
                if adjacent {
                    mergeBoundary(&last.startBoundary, span.startBoundary, request, isStart: true, policy: policy)
                    mergeBoundary(&last.endBoundary, span.endBoundary, request, isStart: false, policy: policy)
                    if span.endTime > last.endTime {
                        last.endTime = span.endTime
                        last.endSegmentID = span.endSegmentID
                    }
                    last.confidence = rustMin(last.confidence, span.confidence)
                    tiers[tier][tiers[tier].count - 1] = last
                    continue
                }
            }
            tiers[tier].append(span)
        }
        result.spans = sortedByTime(tiers[0] + tiers[1])
        if entireRequest && result.spans.contains(where: { span in
            Double(positions[span.endSegmentID]! - positions[span.startSegmentID]! + 1)
                > Double(segments.count) * maxRequestCoverage
        }) {
            result.issues.append("v3_merged_covers_request")
        }
        if result.spans.contains(where: { $0.endTime - $0.startTime > policy.limits.maxBreakSeconds }) {
            result.issues.append("v3_merged_break_duration")
        }
        // Count each second once even where the confidence tiers overlap.
        var coveredEnd = -Double.infinity
        var duration = 0.0
        for span in result.spans {
            let uncovered = rustMax(span.endTime - rustMax(span.startTime, coveredEnd), 0)
            coveredEnd = rustMax(coveredEnd, span.endTime)
            duration += uncovered
        }
        if entireRequest && duration > episodeAdBudgetSeconds(request.transcript, policy: policy) {
            result.issues.append("v3_ad_budget_exceeded")
        }
        return result
    }

    /// Where a receipt occurs in a segment, in normalized tokens: the start
    /// and end offsets of its single occurrence and the segment's token
    /// count. `nil` when it is too long, empty, absent or repeated.
    static func receiptPosition(_ text: String, _ quote: String, policy: AdDetectionPolicy) -> (start: Int, end: Int, total: Int)? {
        if quote.utf8.count > maxQuoteBytes { return nil }
        let words = RustText.normalizedReceiptTokens(text)
        let quoteWords = RustText.normalizedReceiptTokens(quote)
        if quoteWords.isEmpty || quoteWords.count > AdPipelineConstants.maxReceiptWords { return nil }
        let positions = words.occurrences(of: quoteWords)
        guard positions.count == 1 else { return nil }
        return (positions[0], positions[0] + quoteWords.count, words.count)
    }

    /// Coarse trimming can hide the outermost original boundary. Keeps the
    /// outermost anchor that still resolves; drops both when either cannot.
    static func mergeBoundary(
        _ current: inout AdBoundary?,
        _ incoming: AdBoundary?,
        _ request: AdAnalysisRequest,
        isStart: Bool,
        policy: AdDetectionPolicy
    ) {
        func position(_ anchor: AdBoundary) -> (Int, Int)? {
            guard let index = request.segments.firstIndex(where: { $0.id == anchor.segmentID }),
                  let receipt = receiptPosition(request.segments[index].text, anchor.quote, policy: policy)
            else { return nil }
            return (index, isStart ? receipt.start : receipt.end)
        }
        let selected = current.flatMap(position)
        let candidate = incoming.flatMap(position)
        switch (selected, candidate) {
        case let (old?, new?):
            if (isStart && new < old) || (!isStart && new > old) {
                current = incoming
            }
        default:
            current = nil
        }
    }

    static func segmentPositions(_ request: AdAnalysisRequest) -> [Int64: Int] {
        var positions: [Int64: Int] = [:]
        for (index, segment) in request.segments.enumerated() {
            positions[segment.id] = index
        }
        return positions
    }

    static func joinedText(_ segments: ArraySlice<AnalysisSegment>) -> String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Stable sort by start time, then end time, in IEEE total order.
    static func sortedByTime(_ spans: [AdAnalysisSpan]) -> [AdAnalysisSpan] {
        spans.enumerated().sorted { lhs, rhs in
            if let order = totalOrder(lhs.element.startTime, rhs.element.startTime) { return order }
            if let order = totalOrder(lhs.element.endTime, rhs.element.endTime) { return order }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// `true` / `false` when `a` sorts before / after `b`; `nil` when equal.
    static func totalOrder(_ a: Double, _ b: Double) -> Bool? {
        let below = a.isTotallyOrdered(belowOrEqualTo: b)
        let above = b.isTotallyOrdered(belowOrEqualTo: a)
        if below && above { return nil }
        return below
    }
}

/// Rust `f64::max`: ignores a NaN operand.
func rustMax(_ a: Double, _ b: Double) -> Double {
    if a.isNaN { return b }
    if b.isNaN { return a }
    return a >= b ? a : b
}

/// Rust `f64::min`: ignores a NaN operand.
func rustMin(_ a: Double, _ b: Double) -> Double {
    if a.isNaN { return b }
    if b.isNaN { return a }
    return a <= b ? a : b
}
