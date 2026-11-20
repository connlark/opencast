import Foundation
import SwiftUI

/// Grammar agreement resolves only on the attributed localization path, so the counts go
/// through `AttributedString`.
struct PlaylistSummaryText: View {
    let itemCount: Int
    let totalDuration: TimeInterval
    var counts: PlaylistCounts?

    var body: some View {
        Text(Self.line(itemCount: itemCount, totalDuration: totalDuration, counts: counts))
            .accessibilityLabel(Self.spokenLine(itemCount: itemCount, totalDuration: totalDuration, counts: counts))
    }

    static func line(itemCount: Int, totalDuration: TimeInterval, counts: PlaylistCounts? = nil) -> String {
        if let counts, counts.unplayedCount < counts.itemCount {
            let unplayed = "\(counts.unplayedCount) unplayed of \(counts.itemCount)"
            guard counts.remainingDuration > 0 else {
                return unplayed
            }
            return "\(unplayed) · \(PlaylistDurationFormat.short(counts.remainingDuration)) left"
        }
        guard itemCount > 0 else {
            return "No episodes"
        }
        let episodes = inflectedEpisodes(itemCount)
        guard totalDuration > 0 else {
            return episodes
        }
        return "\(episodes) · \(PlaylistDurationFormat.short(totalDuration))"
    }

    static func spokenLine(itemCount: Int, totalDuration: TimeInterval, counts: PlaylistCounts? = nil) -> String {
        if let counts, counts.unplayedCount < counts.itemCount {
            let unplayed = "\(counts.unplayedCount) unplayed of \(counts.itemCount)"
            guard counts.remainingDuration > 0 else {
                return unplayed
            }
            return "\(unplayed), \(PlaylistDurationFormat.spoken(counts.remainingDuration)) left"
        }
        guard itemCount > 0 else {
            return "No episodes"
        }
        let episodes = inflectedEpisodes(itemCount)
        guard totalDuration > 0 else {
            return episodes
        }
        return "\(episodes), \(PlaylistDurationFormat.spoken(totalDuration))"
    }

    static func smartLine(itemCount: Int, totalDuration: TimeInterval) -> String {
        line(itemCount: itemCount, totalDuration: totalDuration)
    }

    static func smartSpokenLine(itemCount: Int, totalDuration: TimeInterval) -> String {
        guard itemCount > 0 else {
            return "Smart playlist, no episodes"
        }
        return "Smart playlist, \(spokenLine(itemCount: itemCount, totalDuration: totalDuration))"
    }

    private static func inflectedEpisodes(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) episode](inflect: true)").characters)
    }
}
