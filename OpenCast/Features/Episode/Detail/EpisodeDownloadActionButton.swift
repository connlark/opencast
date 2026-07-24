import SwiftUI

/// The action bar's stateful download control: idle arrow, cancelable
/// progress ring while downloading, and a Downloaded menu once complete.
struct EpisodeDownloadActionButton: View {
    let record: EpisodeDownloadRecord?
    var liveProgress: DownloadByteProgress?
    let glassNamespace: Namespace.ID
    let buttonSize: CGFloat
    let iconSize: CGFloat
    let onDownload: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isConfirmingCancel = false

    private static let glassID = "episodeActions.download"

    var body: some View {
        switch record?.state {
        case .downloading:
            downloadingButton
        case .completed:
            downloadedMenu
        case .paused:
            idleButton("Resume Download", action: onResume)
        case .failed, .missing, nil:
            idleButton("Download", action: onDownload)
        }
    }

    private func idleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "arrow.down.circle")
                    .resizable()
                    .scaledToFit()
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: iconSize, height: iconSize)
            }
            .labelStyle(.iconOnly)
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(Self.glassID, in: glassNamespace)
        .accessibilityLabel(title)
    }

    private var downloadingButton: some View {
        Button(action: confirmCancel) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 4)
                if let fraction = downloadFraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    ProgressView()
                }
            }
            .animation(.smooth, value: downloadFraction)
            .frame(width: iconSize, height: iconSize)
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(Self.glassID, in: glassNamespace)
        .accessibilityLabel("Downloading")
        .accessibilityValue(downloadAccessibilityValue)
        .accessibilityHint("Cancels the download.")
        .confirmationDialog(
            "Cancel this download?",
            isPresented: $isConfirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel Download", role: .destructive, action: onCancel)
            Button("Keep Downloading", role: .cancel) {}
        }
    }

    private var downloadedMenu: some View {
        Menu {
            Button("Delete Download", systemImage: "trash", role: .destructive, action: onDelete)
        } label: {
            Label {
                Text("Downloaded")
            } icon: {
                Image(systemName: "checkmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize * 0.82, height: iconSize * 0.82)
            }
            .labelStyle(.iconOnly)
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(Self.glassID, in: glassNamespace)
        .accessibilityLabel("Downloaded")
    }

    private func confirmCancel() {
        isConfirmingCancel = true
    }

    private var downloadFraction: Double? {
        if let fraction = liveProgress?.fractionCompleted {
            return fraction
        }
        guard let record, let expected = record.bytesExpected, expected > 0 else {
            return nil
        }
        return min(max(Double(record.bytesReceived) / Double(expected), 0), 1)
    }

    private var downloadAccessibilityValue: String {
        guard let fraction = downloadFraction else {
            return "In progress"
        }
        return "\(Int((fraction * 100).rounded())) percent"
    }
}

#Preview("Dark") {
    @Previewable @Namespace var namespace
    GlassEffectContainer {
        HStack(spacing: 24) {
            EpisodeDownloadActionButton(
                record: nil,
                glassNamespace: namespace,
                buttonSize: 60,
                iconSize: 26,
                onDownload: {}, onResume: {}, onCancel: {}, onDelete: {}
            )
            EpisodeDownloadActionButton(
                record: EpisodeDownloadRecord(
                    episodeID: "preview",
                    podcastID: "preview",
                    sourceAudioURL: "https://example.com/a.mp3",
                    state: .downloading,
                    bytesReceived: 62,
                    bytesExpected: 100
                ),
                glassNamespace: namespace,
                buttonSize: 60,
                iconSize: 26,
                onDownload: {}, onResume: {}, onCancel: {}, onDelete: {}
            )
            EpisodeDownloadActionButton(
                record: EpisodeDownloadRecord(
                    episodeID: "preview",
                    podcastID: "preview",
                    sourceAudioURL: "https://example.com/a.mp3",
                    state: .completed
                ),
                glassNamespace: namespace,
                buttonSize: 60,
                iconSize: 26,
                onDownload: {}, onResume: {}, onCancel: {}, onDelete: {}
            )
        }
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    @Previewable @Namespace var namespace
    EpisodeDownloadActionButton(
        record: nil,
        glassNamespace: namespace,
        buttonSize: 60,
        iconSize: 26,
        onDownload: {}, onResume: {}, onCancel: {}, onDelete: {}
    )
    .padding()
    .preferredColorScheme(.light)
}
