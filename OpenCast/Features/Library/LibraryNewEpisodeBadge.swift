import SwiftUI

/// Red glass count ball on Library grid tiles and list rows. Decorative: the
/// link carries the spoken value, so the badge stays out of the accessibility
/// tree instead of reading the number twice.
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
        // Grows with text size, but stops before it hides the artwork or
        // crowds a row's title; the link's spoken value carries the exact count.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .monospacedDigit()
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
        // A touch wider than tall, so a single digit sits in a ball and longer
        // counts stretch into a pill.
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background { gloss }
        .glassEffect(.regular.tint(.red.opacity(0.9)), in: .capsule)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
        .accessibilityHidden(true)
    }

    /// A soft bright rim plus top-leading and bottom-trailing glints, drawn over
    /// the glass so the badge reads as a lit gel ball instead of a flat pill.
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

    /// The link value rows and tiles share; empty when there is nothing new.
    static func accessibilityValue(count: Int) -> Text {
        count > 0 ? Text("^[\(count) new episode](inflect: true)") : Text(verbatim: "")
    }
}
