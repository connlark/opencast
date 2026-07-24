actor AsyncTestGate {
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}
