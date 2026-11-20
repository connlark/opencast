import SwiftUI

struct HelpFooterLink: View {
    @Environment(OpenCastAppModel.self) private var appModel

    let title: String
    let topicID: String

    @State private var sheetDestination: SheetDestination?

    var body: some View {
        Button(action: showTopic) {
            Text("\(title)…")
                .font(.footnote)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Help Link \(topicID)")
        .sheet(item: $sheetDestination) { destination in
            // Sheets inherit the presenting view's environment, and Section
            // footers style their content footnote/secondary.
            SheetDestinationView(destination: destination, onDismiss: dismissSheet)
                .environment(appModel)
                .font(.body)
                .foregroundStyle(Color.primary)
        }
    }

    private func showTopic() {
        sheetDestination = .helpTopic(id: topicID)
    }

    private func dismissSheet() {
        sheetDestination = nil
    }
}
