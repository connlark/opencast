import Darwin
import Foundation
import Synchronization

/// Samples the process physical footprint (the jetsam-relevant ledger) on a
/// 50 ms cadence so benchmark runs can report a per-run peak alongside
/// start/end values. Sub-50 ms transients can slip between samples; report
/// consumers treat the peak as a floor, not an exact maximum.
nonisolated final class MemoryFootprintSampler: Sendable {
    private let peakBytes = Mutex<Int64>(0)
    private let samplingTask = Mutex<Task<Void, Never>?>(nil)

    static func currentFootprintBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }

    func start() {
        peakBytes.withLock { $0 = Self.currentFootprintBytes() ?? 0 }
        samplingTask.withLock { task in
            task?.cancel()
            task = Task { await self.sampleLoop() }
        }
    }

    /// Final sample is taken at stop so short runs still record an end state.
    func stop() -> Int64 {
        samplingTask.withLock { task in
            task?.cancel()
            task = nil
        }
        if let final = Self.currentFootprintBytes() {
            peakBytes.withLock { $0 = max($0, final) }
        }
        return peakBytes.withLock { $0 }
    }

    @concurrent
    private func sampleLoop() async {
        while !Task.isCancelled {
            if let sample = Self.currentFootprintBytes() {
                peakBytes.withLock { $0 = max($0, sample) }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
