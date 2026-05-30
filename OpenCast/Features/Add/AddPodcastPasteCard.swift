import SwiftUI

struct AddPodcastPasteCard: View {
    let isPasteEnabled: Bool
    let onPaste: () -> Void

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

            Button("Paste", action: onPaste)
                .disabled(!isPasteEnabled)
                .buttonStyle(.glassProminent)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}
