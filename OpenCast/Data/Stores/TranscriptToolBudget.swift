import Synchronization

/// Forced tool calling made the model loop for minutes, and allowed calling still re-searches
/// now and then, so past the cap every tool answers with an instruction to stop.
nonisolated final class TranscriptToolBudget: Sendable {
    static let stopMessage = """
        You have used every transcript lookup allowed for this question. Stop searching and answer now \
        from the passages already returned. If they do not answer the question, set isAnswerable to false.
        """

    let maximumCallsPerTurn: Int
    private let callsMade = Mutex(0)

    init(maximumCallsPerTurn: Int) {
        self.maximumCallsPerTurn = maximumCallsPerTurn
    }

    var callCount: Int {
        callsMade.withLock { $0 }
    }

    func beginTurn() {
        callsMade.withLock { $0 = 0 }
    }

    /// Counts the call; false once the turn's allowance is spent.
    func beginCall() -> Bool {
        callsMade.withLock { calls in
            calls += 1
            return calls <= maximumCallsPerTurn
        }
    }
}
