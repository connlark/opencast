import Foundation

actor ProcessResidentMemorySampler {
    struct Measurement: Sendable {
        let bytesAtStart: Int64?
        let peakBytes: Int64?

        var increaseBytes: Int64? {
            guard let bytesAtStart, let peakBytes else {
                return nil
            }
            return max(0, peakBytes - bytesAtStart)
        }
    }

    private var bytesAtStart: Int64?
    private var peakBytes: Int64?
    private var samplingTask: Task<Void, Never>?

    func start() {
        guard samplingTask == nil else {
            return
        }
        capture()
        bytesAtStart = peakBytes
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await self.capture()
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return
                }
            }
        }
    }

    func stop() async -> Measurement {
        samplingTask?.cancel()
        await samplingTask?.value
        samplingTask = nil
        capture()
        return Measurement(
            bytesAtStart: bytesAtStart,
            peakBytes: peakBytes
        )
    }

    private func capture() {
        guard let currentBytes = MemoryFootprintSampler.currentFootprintBytes() else {
            return
        }
        peakBytes = max(peakBytes ?? currentBytes, currentBytes)
    }
}
