import Synchronization

/// Caps how many tool calls one Ask turn may make. Forced tool calling made
/// the model loop for minutes; with calling merely allowed it still
/// occasionally re-searches, so past the cap every tool answers with an
/// instruction to stop and answer instead of more passages.
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
