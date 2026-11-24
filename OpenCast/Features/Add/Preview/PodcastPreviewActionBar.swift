import OpenCastCore
import SwiftUI

struct PodcastPreviewActionBar: View {
    enum Action {
        case waiting
        case subscribe
        case goToShow
    }

    let action: Action?
    var sample: Episode?
    let failureMessage: String?
    let onSubscribe: () -> Void
    let onGoToShow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failureMessage {
                Label {
                    Text("Couldn’t Subscribe. \(failureMessage)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            GlassEffectContainer(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        buttons
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 10) {
                        buttons
                    }
                }
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var buttons: some View {
        switch action {
        case .waiting:
            Button(action: onSubscribe) {
                Label {
                    Text("Subscribe")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(true)
            .accessibilityIdentifier("Podcast Preview Subscribe")
        case .subscribe:
            Button(action: onSubscribe) {
                Label("Subscribe", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("Podcast Preview Subscribe")
        case .goToShow:
            Button(action: onGoToShow) {
                Text("Go to Show")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        case nil:
            EmptyView()
        }

        if let sample {
            PodcastPreviewSampleButton(episode: sample)
        }
    }
}
