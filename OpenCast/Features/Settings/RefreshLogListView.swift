import SwiftUI

struct RefreshLogListView: View {
    let logs: [RefreshLogSnapshot]

    var body: some View {
        List(logs) { log in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(log.feedURL)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text((log.finishedAt ?? log.startedAt), format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = log.errorMessage, !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    Label("Succeeded", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
        .navigationTitle("Refresh Logs")
    }
}
