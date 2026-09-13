import Foundation

actor ResumeWidgetArtworkGate {
    private var loadContinuation: CheckedContinuation<Data?, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func load() async -> Data? {
        await withCheckedContinuation { continuation in
            loadContinuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilStarted() async {
        guard loadContinuation == nil else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func complete() {
        loadContinuation?.resume(returning: nil)
        loadContinuation = nil
    }
}
