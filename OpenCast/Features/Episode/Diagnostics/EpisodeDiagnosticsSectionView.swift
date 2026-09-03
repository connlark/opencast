import SwiftUI

/// Renders one diagnostics section: its rows once available and a spinner
/// while loading or refining.
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
