import SwiftUI

struct DiagnosticsRefreshLogsSection: View {
    let refreshLogs: [RefreshLogSnapshot]?

    var body: some View {
        Section("Refresh Logs") {
            if let latestRefreshLog = refreshLogs?.first {
                RefreshLogSummaryRow(title: "Latest Refresh", log: latestRefreshLog)
            } else {
                LabeledContent("Latest Refresh", value: "Never")
            }

            if let latestRefreshFailure {
                RefreshLogSummaryRow(title: "Latest Failure", log: latestRefreshFailure)
            } else {
                LabeledContent("Latest Failure", value: "None")
            }

            LabeledContent("Retained Logs", value: refreshLogs.map { "\($0.count)" } ?? "Not Loaded")

            if let refreshLogs, !refreshLogs.isEmpty {
                NavigationLink(value: AppRoute.settings(.refreshLogs)) {
                    Label("Recent Logs", systemImage: "list.bullet.clipboard")
                }
            }
        }
    }

    private var latestRefreshFailure: RefreshLogSnapshot? {
        refreshLogs?.first { !($0.errorMessage ?? "").isEmpty }
    }
}
