import SwiftUI

struct HelpBulletsBlockView: View {
    let items: [AttributedString]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("•")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
