import SwiftData
import SwiftUI

/// A show in Auto Add to Up Next with its Off / Top / Bottom choice, which
/// applies on change. Accessibility sizes put the choice below the show.
struct UpNextAutoAddShowRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let subscription: SubscriptionRecord

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            SettingsShowLabel(subscription: subscription, summary: nil)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Add to Up Next", selection: positionBinding) {
                Text("Off")
                    .tag(UpNextAutoAddPosition?.none)
                Divider()
                ForEach(UpNextAutoAddPosition.allCases) { position in
                    Text(position.title)
                        .tag(Optional(position))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("up-next-auto-add-show-\(subscription.feedURL)")
        }
    }

    private var positionBinding: Binding<UpNextAutoAddPosition?> {
        Binding {
            appModel.library.podcastUpNextAutoAddPosition(forPodcastID: subscription.feedURL)
        } set: { position in
            appModel.setUpNextAutoAddPosition(
                position,
                forPodcastID: subscription.feedURL,
                modelContext: modelContext
            )
        }
    }
}
