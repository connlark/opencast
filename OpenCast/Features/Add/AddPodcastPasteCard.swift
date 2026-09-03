import SwiftUI

struct AddPodcastPasteCard: View {
    let isPasteEnabled: Bool
    let usesSystemPasteButton: Bool
    let onPaste: () -> Void
    let onPastedString: (String) -> Void

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "doc.on.clipboard")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                Text("Paste from Clipboard")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)

                Text("We'll paste the URL you copied to your clipboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
            }

            Spacer(minLength: 12)

            if usesSystemPasteButton {
                // The system paste control reads the pasteboard without the
                // paste-permission alert; the tap itself is the grant.
                PasteButton(payloadType: String.self, onPaste: handlePastedStrings)
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
                    .disabled(!isPasteEnabled)
            } else {
                Button("Paste", action: onPaste)
                    .disabled(!isPasteEnabled)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func handlePastedStrings(_ pastedStrings: [String]) {
        guard let pastedString = pastedStrings.first else {
            return
        }
        onPastedString(pastedString)
    }
}
