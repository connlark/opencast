import SwiftUI

struct DirectoryFeedCandidateMetadataRow: View {
    let label: String
    let value: Text

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                labelText

                Spacer(minLength: 12)

                valueText
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 3) {
                labelText

                valueText
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(label)
            .foregroundStyle(.secondary)
    }

    private var valueText: some View {
        value
            .textSelection(.enabled)
    }
}
