import SwiftUI

struct OnboardingOPMLImportActionCard: View {
    let state: OPMLImportState
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)

                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                SymbolBadgeView(
                    systemImage: statusSystemImage,
                    color: statusColor,
                    isShowingProgress: isImporting
                )
            }
            .accessibilityElement(children: .combine)

            if showsImportButton {
                Button(action: importAction) {
                    Label("Import OPML", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }

            if case .imported(let result) = state {
                Divider()

                OPMLImportSummaryView(result: result)
                    .font(.subheadline)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var statusTitle: String {
        switch state {
        case .idle:
            "Ready to import"
        case .importing:
            "Importing subscriptions"
        case .imported:
            "Subscriptions imported"
        case .failed:
            "Import needs another try"
        }
    }

    private var statusMessage: String {
        switch state {
        case .idle:
            "Choose an OPML file from Files. You can keep going after the import finishes."
        case .importing:
            "Reading your OPML file and adding those RSS feeds."
        case .imported:
            "Your imported feeds are ready for podcast setup."
        case .failed(let message):
            message
        }
    }

    private var statusSystemImage: String {
        switch state {
        case .idle:
            "square.and.arrow.down"
        case .importing:
            "square.and.arrow.down"
        case .imported:
            "checkmark"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch state {
        case .failed:
            .orange
        default:
            .red
        }
    }

    private var isImporting: Bool {
        if case .importing = state {
            return true
        }

        return false
    }

    private var showsImportButton: Bool {
        switch state {
        case .idle, .failed:
            true
        case .importing, .imported:
            false
        }
    }
}
