import SwiftUI

struct EpisodeDownloadControlsView: View {
    let record: EpisodeDownloadRecord?
    let lastErrorMessage: String?
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onPlayDownloaded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch record?.state {
            case nil:
                Text("Streaming remains the default. Downloads are foreground-only and stay on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                fullWidthButton("Download", systemImage: "arrow.down.circle", action: onDownload)
            case .downloading:
                downloadingView
                fullWidthButton("Cancel Download", systemImage: "xmark.circle", role: .cancel, action: onCancel)
            case .completed:
                completedView
                fullWidthButton("Play Downloaded", systemImage: "play.circle", action: onPlayDownloaded)
                fullWidthButton("Delete Download", systemImage: "trash", role: .destructive, action: onDelete)
            case .failed:
                failedView(title: "Download Failed")
                fullWidthButton("Retry Download", systemImage: "arrow.clockwise", action: onDownload)
                fullWidthButton("Delete Download", systemImage: "trash", role: .destructive, action: onDelete)
            case .missing:
                failedView(title: "Downloaded File Missing")
                fullWidthButton("Retry Download", systemImage: "arrow.clockwise", action: onDownload)
                fullWidthButton("Delete Download", systemImage: "trash", role: .destructive, action: onDelete)
            }

            if let lastErrorMessage, record == nil {
                Label(lastErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var downloadingView: some View {
        if let record,
           let bytesExpected = record.bytesExpected,
           bytesExpected > 0 {
            ProgressView(
                value: Double(record.bytesReceived),
                total: Double(bytesExpected)
            ) {
                Text("Downloading")
                    .font(.headline)
            } currentValueLabel: {
                Text("\(byteCount(record.bytesReceived)) of \(byteCount(bytesExpected))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Download Progress")
            .accessibilityValue("\(byteCount(record.bytesReceived)) of \(byteCount(bytesExpected))")
        } else {
            ProgressView("Downloading")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var completedView: some View {
        if let record {
            Label("Downloaded, \(byteCount(record.bytesReceived)), local only", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func failedView(title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(record?.errorMessage ?? lastErrorMessage ?? "Try downloading this episode again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func fullWidthButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private func byteCount(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
