import SwiftUI

struct RefreshLogSummaryRow: View {
    let title: String
    let log: RefreshLogSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(displayDate, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }

            Text(log.feedURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let errorMessage = log.errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var displayDate: Date {
        log.finishedAt ?? log.startedAt
    }
}
