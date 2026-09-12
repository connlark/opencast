#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import SwiftUI

struct NotificationRouteDiagnosticsSection: View {
    @State private var diagnostics = RemoteEpisodeNotificationRouteDiagnostics.shared

    var body: some View {
        Section("Notification Route") {
            LabeledContent("Route Status", value: diagnostics.status)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Route Status, \(diagnostics.status)")

            LabeledContent("Route Events", value: "\(diagnostics.eventCount)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Route Events, \(diagnostics.eventCount)")

            LabeledContent("Route Title", value: diagnostics.episodeTitle ?? "None")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Route Title, \(diagnostics.episodeTitle ?? "None")")

            if let episodeID = diagnostics.episodeID {
                LabeledContent("Route Episode", value: Self.shortID(episodeID))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Route Episode, \(episodeID)")
            }

            if let canonicalFeedURL = diagnostics.canonicalFeedURL ?? diagnostics.feedURL {
                LabeledContent("Route Feed", value: canonicalFeedURL)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Route Feed, \(canonicalFeedURL)")
            }

            if let updatedAt = diagnostics.updatedAt {
                LabeledContent {
                    Text(updatedAt, format: .dateTime.hour().minute().second())
                } label: {
                    Text("Route Updated")
                }
            }
        }
    }

    private static func shortID(_ id: String) -> String {
        guard id.count > 12 else {
            return id
        }

        return String(id.prefix(12))
    }
}
#endif
