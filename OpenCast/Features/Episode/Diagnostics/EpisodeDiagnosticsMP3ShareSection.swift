import SwiftData
import SwiftUI

/// The Download & Share Audio controls: immediate share when a completed
/// download exists, otherwise the reused foreground download with live byte
/// progress and an explicit cancel that stops the download itself.
struct EpisodeDiagnosticsMP3ShareSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let model: EpisodeDiagnosticsModel

    var body: some View {
        switch model.mp3ShareState {
        case .idle:
            Button("Download & Share Audio", systemImage: "square.and.arrow.up", action: shareMP3)
        case .waitingForDownload:
            if let progress = appModel.downloads.byteProgress(for: model.episodeID) {
                LabeledContent("Downloading") {
                    Text(byteProgressText(progress))
                        .font(.footnote)
                        .monospaced()
                }
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                }
            } else {
                ProgressView("Waiting for download")
            }
            Button("Cancel Download", systemImage: "xmark.circle", role: .destructive, action: cancelDownload)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
            Button("Retry Download & Share", systemImage: "arrow.clockwise", action: shareMP3)
        }
    }

    private func byteProgressText(_ progress: DownloadByteProgress) -> String {
        let received = progress.bytesReceived.formatted(.byteCount(style: .file))
        guard let expected = progress.bytesExpected else {
            return received
        }
        return "\(received) of \(expected.formatted(.byteCount(style: .file)))"
    }

    private func shareMP3() {
        model.shareMP3(appModel: appModel, modelContext: modelContext)
    }

    private func cancelDownload() {
        model.cancelSharedDownload(appModel: appModel, modelContext: modelContext)
    }
}
