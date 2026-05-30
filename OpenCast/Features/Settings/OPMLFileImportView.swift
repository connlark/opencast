import Foundation
import SwiftData
import SwiftUI

struct OPMLFileImportView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let url: URL

    @State private var importFlow = OPMLImportFlow()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("File", value: url.lastPathComponent)

                    OPMLImportStateView(
                        state: importFlow.state,
                        importAction: importSubscriptions
                    )
                } footer: {
                    Text(OPMLImportCopy.subscriptionsOnlyFooter)
                }
            }
            .navigationTitle("Import Subscriptions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCancelAction {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: dismissSheet)
                    }
                }

                if showsDoneAction {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: dismissSheet)
                    }
                }
            }
            .interactiveDismissDisabled(importFlow.state.isImporting)
            .onDisappear {
                importFlow.cancelImportTask()
            }
        }
    }

    private func importSubscriptions() {
        guard !importFlow.state.isImporting else {
            return
        }

        importFlow.importSubscriptions(
            from: url,
            libraryStore: appModel.library,
            modelContext: modelContext
        )
    }

    private var showsCancelAction: Bool {
        switch importFlow.state {
        case .idle, .failed:
            true
        case .importing, .imported:
            false
        }
    }

    private var showsDoneAction: Bool {
        if case .imported = importFlow.state {
            return true
        }

        return false
    }

    private func dismissSheet() {
        dismiss()
    }
}
