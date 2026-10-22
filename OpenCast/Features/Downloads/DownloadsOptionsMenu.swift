import SwiftData
import SwiftUI

/// The Downloads tab's options: the Unplayed Only filter, Group by Show
/// (kept on this device) and Remove Played behind a confirmation.
struct DownloadsOptionsMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var isConfirmingRemovePlayed = false

    @Binding var showsUnplayedOnly: Bool
    let playedDownloadCount: Int
    let onRemovePlayed: () -> Void

    var body: some View {
        Menu {
            Section {
                Toggle(isOn: $showsUnplayedOnly) {
                    Label("Unplayed Only", systemImage: "circle")
                }

                Toggle(isOn: groupsByShowBinding) {
                    Label("Group by Show", systemImage: "square.stack")
                }
            }

            Button(
                "Remove Played",
                systemImage: "checkmark.circle",
                role: .destructive,
                action: confirmRemovePlayed
            )
            .disabled(playedDownloadCount == 0)
        } label: {
            Label("Download Options", systemImage: "ellipsis.circle")
        }
        .confirmationDialog(
            "Remove played downloads?",
            isPresented: $isConfirmingRemovePlayed,
            titleVisibility: .visible
        ) {
            Button("Remove Played", role: .destructive, action: onRemovePlayed)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Played downloads that aren’t currently in use will be removed from this device.")
        }
    }

    private var groupsByShowBinding: Binding<Bool> {
        Binding {
            appModel.downloadSettings.listGrouping == .byShow
        } set: { groupsByShow in
            appModel.setDownloadsListGrouping(groupsByShow ? .byShow : .flat, modelContext: modelContext)
        }
    }

    private func confirmRemovePlayed() {
        isConfirmingRemovePlayed = true
    }
}
