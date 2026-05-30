import SwiftUI

struct OPMLImportStateView: View {
    let state: OPMLImportState
    let showsImportButtonAfterSuccess: Bool
    let importButtonTitle: String
    let importAction: () -> Void

    init(
        state: OPMLImportState,
        showsImportButtonAfterSuccess: Bool = false,
        importButtonTitle: String = "Import Subscriptions",
        importAction: @escaping () -> Void
    ) {
        self.state = state
        self.showsImportButtonAfterSuccess = showsImportButtonAfterSuccess
        self.importButtonTitle = importButtonTitle
        self.importAction = importAction
    }

    var body: some View {
        if showsImportButton {
            Button(
                importButtonTitle,
                systemImage: "square.and.arrow.down",
                action: importAction
            )
        }

        switch state {
        case .idle:
            EmptyView()
        case .importing:
            ProgressView("Importing Subscriptions")
        case .imported(let result):
            OPMLImportSummaryView(result: result)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var showsImportButton: Bool {
        switch state {
        case .idle, .failed:
            true
        case .importing:
            false
        case .imported:
            showsImportButtonAfterSuccess
        }
    }
}
