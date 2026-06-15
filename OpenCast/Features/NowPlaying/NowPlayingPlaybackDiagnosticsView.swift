import SwiftUI

struct NowPlayingPlaybackDiagnosticsView: View {
    private let cornerRadius: CGFloat = 8

    let text: String
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.green)
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(minWidth: size, minHeight: size, alignment: .topLeading)
            }
            .scrollIndicators(.visible)

            Button("Copy Diagnostics", systemImage: "doc.on.doc", action: copyDiagnostics)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .padding(8)
        }
        .frame(width: size, height: size)
        .background(.black)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.white.opacity(0.24), lineWidth: 1)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Playback diagnostics")
    }

    private func copyDiagnostics() {
        UIPasteboard.general.string = text
    }
}
