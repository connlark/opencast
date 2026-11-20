import SwiftUI

/// Hidden from accessibility: the link carries the spoken count.
struct LibraryNewEpisodeBadge: View {
    static let displayLimit = 99

    let count: Int

    var body: some View {
        Group {
            if count > Self.displayLimit {
                Text("\(Self.displayLimit)+")
            } else {
                Text(count, format: .number)
            }
        }
        .font(.caption.bold())
        // Capped so it never hides the artwork or crowds a row's title.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .monospacedDigit()
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background { gloss }
        .glassEffect(.regular.tint(.red.opacity(0.9)), in: .capsule)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
        .accessibilityHidden(true)
    }

    private var gloss: some View {
        ZStack {
            Capsule()
                .strokeBorder(.white.opacity(0.35), lineWidth: 3)
                .blur(radius: 1.2)
                .clipShape(.capsule)
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white.opacity(0), location: 0.2),
                            .init(color: .white.opacity(0), location: 0.8),
                            .init(color: .white.opacity(0.75), location: 1),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.8
                )
                .blur(radius: 0.3)
        }
    }

    static func accessibilityValue(count: Int) -> Text {
        count > 0 ? Text("^[\(count) new episode](inflect: true)") : Text(verbatim: "")
    }
}
