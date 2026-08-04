struct TranscriptSearchSession {
    private var generation = 0
    private var activeQuery: String?

    private(set) var isInFlight = false
    private(set) var result = TranscriptSearchResult(query: "")
    private(set) var currentMatchIndex: Int?

    var matchSegmentIDs: [Int] {
        result.matchSegmentIDs
    }

    var highlightRangesBySegmentID: [Int: [Range<String.Index>]] {
        result.highlightRangesBySegmentID
    }

    mutating func begin(query: String) -> Int {
        generation += 1
        activeQuery = query
        isInFlight = true
        return generation
    }

    @discardableResult
    mutating func publish(_ result: TranscriptSearchResult, generation: Int) -> Bool {
        guard generation == self.generation, result.query == activeQuery else {
            return false
        }

        self.result = result
        currentMatchIndex = result.matchSegmentIDs.isEmpty ? nil : 0
        return true
    }

    mutating func finish(generation: Int) {
        guard generation == self.generation else {
            return
        }
        isInFlight = false
    }

    mutating func clear() {
        generation += 1
        activeQuery = nil
        isInFlight = false
        result = TranscriptSearchResult(query: "")
        currentMatchIndex = nil
    }

    mutating func stepMatch(by delta: Int) -> Int? {
        guard !matchSegmentIDs.isEmpty else {
            return nil
        }

        let count = matchSegmentIDs.count
        let next = ((currentMatchIndex ?? 0) + delta + count) % count
        currentMatchIndex = next
        return matchSegmentIDs[next]
    }
}
