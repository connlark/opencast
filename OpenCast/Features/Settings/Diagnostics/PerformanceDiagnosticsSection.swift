import SwiftUI

struct PerformanceDiagnosticsSection: View {
    @State private var reports: [PerformanceReport] = []
    @State private var errorMessage: String?
    @State private var exportURL: URL?
    @State private var isExporting = false

    var body: some View {
        Section {
            LabeledContent("Local Reports", value: reports.count.formatted())
            if let latest = reports.first {
                LabeledContent("Latest Report", value: latest.receivedAt.formatted(date: .abbreviated, time: .shortened))
                Text(summary(latest)).foregroundStyle(.secondary)
            } else {
                Text("Reports arrive from iOS as they become available, usually daily. No reports yet.")
                    .foregroundStyle(.secondary)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            Button("Prepare Export", systemImage: "square.and.arrow.up") { Task { await prepareExport() } }
                .disabled(isExporting || reports.isEmpty)
            if let exportURL { ShareLink("Share Performance Reports", item: exportURL) }
        } header: {
            Text("Performance")
        } footer: {
            Text("Stored on this device only, up to 20 reports or 20 MB. Exports contain performance measurements and app states, without episode titles, transcripts, or feed addresses.")
        }
        .task {
            let updates = await PerformanceReportStore.shared.updates()
            await load()
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private func load() async {
        do {
            reports = try await PerformanceReportStore.shared.reports()
            errorMessage = await PerformanceReportStore.shared.failure()?.localizedDescription
        } catch is CancellationError {
            return
        } catch {
            errorMessage = PerformanceReportError.unavailable.localizedDescription
        }
    }

    private func prepareExport() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let destination = URL.temporaryDirectory.appending(path: "OpenCast-Performance.json")
            exportURL = try await PerformanceReportStore.shared.export(to: destination)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func summary(_ report: PerformanceReport) -> String {
        let launches = report.measurements.filter { $0.name == .launchSeconds }.reduce(0) { $0 + ($1.count ?? 1) }
        let hangs = report.measurements.filter { $0.name == .hangSeconds }.reduce(0) { $0 + ($1.count ?? 1) }
        var parts = ["\(launches) launch measurements", "\(hangs) hang measurements"]
        if let cpu = report.measurements.first(where: { $0.name == .cpuSeconds }) {
            parts.append("\(cpu.value.formatted(.number.precision(.fractionLength(1)))) seconds of CPU time")
        }
        if let hitch = report.measurements.first(where: { $0.name == .animationHitchSeconds }) {
            parts.append("\(hitch.value.formatted(.number.precision(.fractionLength(2)))) seconds of animation hitches")
        }
        return parts.joined(separator: " · ")
    }
}
