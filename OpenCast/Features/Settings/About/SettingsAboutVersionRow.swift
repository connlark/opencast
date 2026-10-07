import SwiftUI

struct SettingsAboutVersionRow: View {
    @State private var copyCount = 0
    @State private var showsCopied = false

    var body: some View {
        Button(action: copyVersion) {
            LabeledContent {
                Text(showsCopied ? "Copied" : OpenCastAppVersion.displayText)
                    .contentTransition(.opacity)
            } label: {
                Label("Version", systemImage: "info.circle")
                    .foregroundStyle(Color.primary)
            }
        }
        .contextMenu {
            Button("Copy Version", systemImage: "doc.on.doc", action: copyVersion)
        }
        .sensoryFeedback(.success, trigger: copyCount)
        .task(id: copyCount, revertCopiedLabel)
        .accessibilityHint("Copies the version")
        .accessibilityIdentifier("About Version")
    }

    private func copyVersion() {
        UIPasteboard.general.string = "opencast \(OpenCastAppVersion.displayText)"
        withAnimation {
            showsCopied = true
        }
        copyCount += 1
    }

    private func revertCopiedLabel() async {
        guard showsCopied else {
            return
        }
        do {
            try await Task.sleep(for: .seconds(1.5))
        } catch {
            return
        }
        withAnimation {
            showsCopied = false
        }
    }
}
