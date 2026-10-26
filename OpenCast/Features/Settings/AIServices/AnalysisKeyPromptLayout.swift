import SwiftUI

/// The layout the key notice and the key screen share: a scrolling title and
/// paragraphs above two full-width glass buttons that stay in view at the
/// medium detent and at accessibility sizes.
struct AnalysisKeyPromptLayout: View {
    let title: String
    let paragraphs: [String]
    let primaryTitle: String
    let primaryIdentifier: String
    let onPrimary: () -> Void
    let secondaryTitle: String
    let secondaryIdentifier: String
    let onSecondary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.title2)
                        .bold()
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .foregroundStyle(Color.primary)
            }
            .scrollBounceBehavior(.basedOnSize)

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    Button(action: onPrimary) {
                        Text(primaryTitle)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier(primaryIdentifier)

                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier(secondaryIdentifier)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }
}

#Preview("Dark") {
    AnalysisKeyPromptLayout(
        title: AIServicesCopy.noticeTitle,
        paragraphs: [
            AIServicesCopy.noticeFirstParagraph(date: "January 1, 2027"),
            AIServicesCopy.noticeSecondParagraph(date: "January 1, 2027", units: 5)
        ],
        primaryTitle: AIServicesCopy.noticeAddKey,
        primaryIdentifier: "Preview Primary",
        onPrimary: {},
        secondaryTitle: AIServicesCopy.noticeLater,
        secondaryIdentifier: "Preview Secondary",
        onSecondary: {}
    )
    .preferredColorScheme(.dark)
}
