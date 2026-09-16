import Foundation
import OpenCastTranscription

/// Immutable lexical retrieval over one transcript, built once per document
/// beside `TranscriptSearchIndex`. Consecutive segments merge into passages
/// of about ninety seconds or a hundred and twenty words; BM25 over folded
/// tokens ranks them for the Ask tools. Building runs off the caller's actor
/// with cancellation checkpoints, like the search index.
nonisolated struct TranscriptPassageIndex: Sendable {
    static let maximumPassageDuration: TimeInterval = 90
    static let maximumPassageWordCount = 120
    static let bm25TermSaturation = 1.2
    static let bm25LengthNormalization = 0.75

    private static let cancellationCheckStride = 64

    let passages: [TranscriptPassage]
    private let documentFrequencies: [String: Int]
    private let averagePassageTokenCount: Double

    private init(passages: [TranscriptPassage]) {
        self.passages = passages
        var frequencies: [String: Int] = [:]
        for passage in passages {
            for term in passage.termFrequencies.keys {
                frequencies[term, default: 0] += 1
            }
        }
        documentFrequencies = frequencies
        averagePassageTokenCount = passages.isEmpty
            ? 1
            : Double(passages.reduce(0) { $0 + $1.tokenCount }) / Double(passages.count)
    }

    @concurrent
    static func build(
        segments: [OpenCastTranscriptSegment],
        checkpoint: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> TranscriptPassageIndex {
        try Task.checkCancellation()
        var passages: [TranscriptPassage] = []
        var run: [OpenCastTranscriptSegment] = []
        var runWordCount = 0
        var runTokens: [String] = []

        func closeRun() {
            guard !run.isEmpty else {
                return
            }
            var frequencies: [String: Int] = [:]
            for token in runTokens {
                frequencies[token, default: 0] += 1
            }
            passages.append(TranscriptPassage(
                id: passages.count,
                segments: run,
                termFrequencies: frequencies,
                tokenCount: runTokens.count
            ))
            run.removeAll(keepingCapacity: true)
            runTokens.removeAll(keepingCapacity: true)
            runWordCount = 0
        }

        for (offset, segment) in segments.enumerated() {
            if offset.isMultiple(of: cancellationCheckStride) {
                await checkpoint?(offset)
                try Task.checkCancellation()
            }
            let words = segment.text.split(whereSeparator: \.isWhitespace).count
            let wouldOverrun = !run.isEmpty
                && (segment.end - run[0].start > maximumPassageDuration
                    || runWordCount + words > maximumPassageWordCount)
            if wouldOverrun {
                closeRun()
            }
            run.append(segment)
            runWordCount += words
            runTokens.append(contentsOf: TranscriptPassageTokenizer.tokens(in: segment.text))
        }
        closeRun()
        try Task.checkCancellation()
        return TranscriptPassageIndex(passages: passages)
    }

    /// Passages ranked by BM25 for the query's tokens; ties keep transcript
    /// order. Empty when no passage shares a token with the query.
    func search(_ query: String, limit: Int) -> [TranscriptPassage] {
        let terms = Set(TranscriptPassageTokenizer.tokens(in: query))
        guard !terms.isEmpty, limit > 0 else {
            return []
        }
        let passageCount = Double(passages.count)
        var scored: [(score: Double, passage: TranscriptPassage)] = []
        for passage in passages {
            var score = 0.0
            let lengthFactor = 1 - Self.bm25LengthNormalization
                + Self.bm25LengthNormalization * Double(passage.tokenCount) / averagePassageTokenCount
            for term in terms {
                guard let frequency = passage.termFrequencies[term] else {
                    continue
                }
                let documentFrequency = Double(documentFrequencies[term] ?? 0)
                let idf = log(1 + (passageCount - documentFrequency + 0.5) / (documentFrequency + 0.5))
                let tf = Double(frequency)
                score += idf * (tf * (Self.bm25TermSaturation + 1))
                    / (tf + Self.bm25TermSaturation * lengthFactor)
            }
            if score > 0 {
                scored.append((score, passage))
            }
        }
        return scored
            .sorted { $0.score > $1.score || ($0.score == $1.score && $0.passage.id < $1.passage.id) }
            .prefix(limit)
            .map(\.passage)
    }

    /// Passages touching the time range, in transcript order.
    func passages(overlapping range: ClosedRange<TimeInterval>) -> [TranscriptPassage] {
        passages.filter { $0.overlaps(range) }
    }
}
