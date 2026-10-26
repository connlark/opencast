import SwiftUI

/// Settings › Diagnostics: the recent ad detection and Chapters & Summary
/// runs, shareable as a file built from the run records alone.
struct AnalysisRunsDiagnosticsSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @State private var runCount: Int?
    @State private var errorMessage: String?
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        Section {
            LabeledContent("Recorded Runs", value: runCount.map { $0.formatted() } ?? "—")
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            Button("Prepare Export", systemImage: "square.and.arrow.up") {
                exportTask = Task {
                    await prepareExport()
                }
            }
            .disabled(isExporting || runCount == 0)
            .accessibilityIdentifier("Settings Diagnostics Prepare Analysis Runs Export")
            if let exportURL {
                ShareLink("Share Analysis Runs", item: exportURL)
                    .accessibilityIdentifier("Settings Diagnostics Share Analysis Runs")
            }
        } header: {
            Text("Analysis Runs")
        } footer: {
            Text("Stored on this device only, the last \(AnalysisRunsExport.maximumRuns) runs. Exports contain run outcomes, models and token counts, without episode titles, transcripts, keys, or addresses.")
        }
        .task {
            runCount = await Self.count(of: appModel.analysisRuns)
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            removeExport()
        }
    }

    private func prepareExport() async {
        isExporting = true
        defer {
            isExporting = false
        }
        removeExport()
        // Each presentation writes its own copy, so leaving Diagnostics in
        // one window never removes a file another window is sharing.
        let directory = URL.temporaryDirectory.appending(
            path: "AnalysisRuns-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            let url = try await Self.write(from: appModel.analysisRuns, to: directory)
            // A preparation that outlived its section leaves nothing behind.
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            exportURL = url
            errorMessage = nil
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            errorMessage = error.localizedDescription
        }
    }

    private func removeExport() {
        guard let exportURL else {
            return
        }
        try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent())
        self.exportURL = nil
    }

    @concurrent
    private static func count(of runs: AnalysisRunRecordStore) async -> Int {
        runs.records(limit: AnalysisRunsExport.maximumRuns).count
    }

    @concurrent
    private static func write(from runs: AnalysisRunRecordStore, to directory: URL) async throws -> URL {
        let entries = runs.records(limit: AnalysisRunsExport.maximumRuns).map(AnalysisRunsExportEntry.init)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AnalysisRunsExport.write(
            entries: entries,
            generatedAt: .now,
            to: directory.appending(path: AnalysisRunsExport.fileName)
        )
    }
}
