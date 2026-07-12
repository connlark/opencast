actor TranscriptionEventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }

    func waitForPrefix(_ prefix: String) async -> Bool {
        for _ in 0..<100 {
            if events.contains(where: { $0.hasPrefix(prefix) }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
