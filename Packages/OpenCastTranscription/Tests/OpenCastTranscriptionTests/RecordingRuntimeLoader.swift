@testable import OpenCastTranscription

actor RecordingRuntimeLoader: OpenCastTranscriptionRuntimeLoading {
    private let log: TranscriptionEventLog
    private let loadDelay: Duration
    private let decodeDelay: Duration
    private var runtimes: [String: RecordingRuntime] = [:]
    private var loadCounts: [String: Int] = [:]
    private var activeLoadCount = 0
    private var _maxActiveLoadCount = 0

    init(
        log: TranscriptionEventLog,
        loadDelay: Duration = .milliseconds(10),
        decodeDelay: Duration = .milliseconds(10)
    ) {
        self.log = log
        self.loadDelay = loadDelay
        self.decodeDelay = decodeDelay
    }

    var maxActiveLoadCount: Int {
        _maxActiveLoadCount
    }

    func loadCount(for modelIdentifier: String) -> Int {
        loadCounts[modelIdentifier, default: 0]
    }

    func runtime(for modelIdentifier: String) -> RecordingRuntime? {
        runtimes[modelIdentifier]
    }

    func loadRuntime(for location: OpenCastWhisperModelLocation) async throws -> any OpenCastTranscriptionRuntime {
        let modelIdentifier = location.modelIdentifier
        activeLoadCount += 1
        _maxActiveLoadCount = max(_maxActiveLoadCount, activeLoadCount)
        loadCounts[modelIdentifier, default: 0] += 1
        await log.append("load-start:\(modelIdentifier)")

        do {
            try await Task.sleep(for: loadDelay)
            try Task.checkCancellation()
            let runtime = runtimes[modelIdentifier] ?? RecordingRuntime(
                modelIdentifier: modelIdentifier,
                log: log,
                decodeDelay: decodeDelay
            )
            runtimes[modelIdentifier] = runtime
            activeLoadCount -= 1
            await log.append("load-end:\(modelIdentifier)")
            return runtime
        } catch {
            activeLoadCount -= 1
            await log.append("load-cancel:\(modelIdentifier)")
            throw error
        }
    }
}
