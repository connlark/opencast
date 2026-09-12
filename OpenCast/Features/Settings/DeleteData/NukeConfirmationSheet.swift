import SwiftData
import SwiftUI

struct NukeConfirmationSheet: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var confirmationText = ""
    @State private var dataNukeTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This deletes all opencast subscriptions, listening progress, local episode records, downloaded files, automatic caches, and local settings.")

                    TextField("Type NUKE", text: $confirmationText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Nuke Confirmation Text")

                    if appModel.isNukingData {
                        ProgressView("Deleting opencast Data")
                    }

                    if let message = appModel.lastDataNukeErrorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("opencast checks iCloud again before deleting. If iCloud is unavailable, nothing is deleted.")
                }

                Section {
                    Button(
                        "Nuke opencast Data",
                        systemImage: "trash",
                        role: .destructive,
                        action: nukeData
                    )
                    .disabled(!isConfirmationValid || appModel.isNukingData)
                }
            }
            .navigationTitle("Nuke Data")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(appModel.isNukingData)
                }
            }
        }
        .interactiveDismissDisabled(appModel.isNukingData)
        .onAppear(perform: beginNewAttempt)
        .onDisappear(perform: clearDismissedError)
    }

    private var isConfirmationValid: Bool {
        DataNukeConfirmation.isConfirmed(confirmationText)
    }

    private func nukeData() {
        guard isConfirmationValid, !appModel.isNukingData, dataNukeTask == nil else {
            return
        }

        dataNukeTask = Task {
            do {
                try await appModel.nukeAllData(modelContext: modelContext)
                dismiss()
            } catch {
                // The model surfaces failures through lastDataNukeErrorMessage. This task is not a SwiftUI .task,
                // so sheet dismissal cannot cancel a multi-step delete while interactive dismissal is disabled.
            }
            dataNukeTask = nil
        }
    }

    private func cancel() {
        dismiss()
    }

    private func beginNewAttempt() {
        appModel.clearDataNukeError()
    }

    private func clearDismissedError() {
        guard !appModel.isNukingData else {
            return
        }

        appModel.clearDataNukeError()
    }
}
