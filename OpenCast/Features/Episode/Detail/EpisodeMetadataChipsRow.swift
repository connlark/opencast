import SwiftUI

struct EpisodeMetadataChipsRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let chips: [EpisodeMetadataChip]

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        layout {
            ForEach(chips) { chip in
                chipView(chip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.fill.tertiary, in: .capsule)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func chipView(_ chip: EpisodeMetadataChip) -> some View {
        switch chip {
        case .publishDate(let date):
            Text(date, format: .dateTime.month(.abbreviated).day().year())
        case .duration(let text):
            Text(text)
        case .remaining(let text, let fractionCompleted):
            HStack(spacing: 6) {
                EpisodeProgressBarView(fractionCompleted: fractionCompleted)
                    .frame(width: 44)
                Text(text)
            }
        case .downloaded(let fileSize):
            Label(fileSize ?? "Downloaded", systemImage: "arrow.down.circle.fill")
                .accessibilityLabel(fileSize.map { "Downloaded, \($0)" } ?? "Downloaded")
        case .played:
            Label("Played", systemImage: "checkmark")
        }
    }
}

#Preview("Dark") {
    EpisodeMetadataChipsRow(chips: [
        .publishDate(Date(timeIntervalSince1970: 1_780_000_000)),
        .remaining("2h 47m left", fractionCompleted: 0.3),
        .downloaded(fileSize: "42 MB"),
        .played
    ])
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    EpisodeMetadataChipsRow(chips: [
        .publishDate(Date(timeIntervalSince1970: 1_780_000_000)),
        .duration("2h 47m"),
        .downloaded(fileSize: nil)
    ])
    .padding()
    .preferredColorScheme(.light)
}
