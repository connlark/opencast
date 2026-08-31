import SwiftUI

/// Renders one diagnostics section: its rows once available, a spinner while
/// loading or refining, and a local error without touching other sections.
struct EpisodeDiagnosticsSectionView: View {
    let id: EpisodeDiagnosticsSectionID
    let state: EpisodeDiagnosticsSectionState

    var body: some View {
        Section(id.title) {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .partial(let section):
                rows(section)
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .loaded(let section):
                rows(section)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func rows(_ section: EpisodeDiagnosticsSection) -> some View {
        ForEach(section.rows) { row in
            LabeledContent(row.label) {
                Text(row.value)
                    .font(.footnote)
                    .monospaced()
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        if let footnote = section.footnote {
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
