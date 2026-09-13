import Foundation
import Testing
@testable import OpenCast

@Suite("Local performance diagnostics")
struct PerformanceDiagnosticsTests {
    @Test @MainActor func stateDeduplicationAndPrivacy() {
        var states: [PerformanceState] = []
        let reporter = PerformanceStateReporter { states.append($0) }
        for _ in 0..<1000 { reporter.transition(.playback, to: "playing") }
        reporter.transition(.playback, to: "Private episode title")
        reporter.transition(.playback, to: "paused")
        #expect(states.map(\.label) == ["playing", "paused"])
        #expect(reporter.transitionCount == 2)
    }

    @Test func retentionAndAtomicReplacement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceReportStore(directory: directory, maximumCount: 2)
        let first = report()
        try await store.save(first)
        try await store.save(first)
        #expect(try await store.reports().count == 1)
        try await store.save(report())
        try await store.save(report())
        let reports = try await store.reports()
        #expect(reports.count == 2)
        #expect(!reports.contains { $0.id == first.id })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func byteLimitAndOversizeRejection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = report()
        let size = try JSONEncoder().encode(value).count
        let store = PerformanceReportStore(directory: directory, maximumBytes: size + 20)
        try await store.save(value)
        try await store.save(report())
        #expect(try await store.reports().count == 1)
        var oversized = report()
        oversized.measurements = Array(repeating: PerformanceMeasurement(name: .cpuSeconds, value: 1), count: 100)
        await #expect(throws: PerformanceReportError.self) { try await store.save(oversized) }
        #expect(try await store.reports().count == 1)
    }

    @Test func malformedAndExportFailuresSurface() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceReportStore(directory: directory)
        try await store.save(report())
        try Data("invalid".utf8).write(to: directory.appending(path: "malformed.json"))
        await #expect(throws: (any Error).self) { _ = try await store.reports() }
        try FileManager.default.removeItem(at: directory.appending(path: "malformed.json"))
        await #expect(throws: PerformanceReportError.self) {
            _ = try await store.export(to: directory.appending(path: "missing/export.json"))
        }
        let export = directory.deletingLastPathComponent().appending(path: "\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: export) }
        _ = try await store.export(to: export)
        let decoded = try JSONDecoder().decode([PerformanceReport].self, from: Data(contentsOf: export))
        #expect(decoded.count == 1)
        #expect(decoded.first?.states.first?.label == "playing")
    }

    @Test func cancelledSaveLeavesNoFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceReportStore(directory: directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.save(report())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.reports().isEmpty)
    }

    @Test func concurrentReportsRemainBoundedAndComplete() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceReportStore(directory: directory, maximumCount: 5)
        let reports = (0..<30).map { _ in report() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for report in reports {
                group.addTask { try await store.save(report) }
            }
            try await group.waitForAll()
        }
        let retained = try await store.reports()
        #expect(retained.count == 5)
        #expect(Set(retained.map(\.id)).count == 5)
        #expect(retained.allSatisfy { value in reports.contains { $0.id == value.id } })
    }

    @Test func reportNotificationsStopWhenConsumerIsCancelled() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceReportStore(directory: directory)
        let updates = await store.updates()
        await store.receive(report())
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        let consumer = Task {
            var received = 0
            for await _ in updates { received += 1 }
            return received
        }
        consumer.cancel()
        #expect(await consumer.value == 0)
        await store.receive(report())
        #expect(try await store.reports().count == 2)
        #expect(await store.failure() == nil)
    }

    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "performance-tests-\(UUID())", directoryHint: .isDirectory)
    }

    private func report() -> PerformanceReport {
        PerformanceReport(id: UUID(), receivedAt: .now, appVersion: "1.0 (1)", toolchainVersion: "27A266a", kind: .metrics, timeRange: DateInterval(start: .now, duration: 1), states: [PerformanceState(domain: .playback, label: "playing")!])
    }
}
