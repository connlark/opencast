import SwiftData
import SwiftUI

/// The Inbox filter and Hide Up Next toggle as a trailing toolbar menu.
/// While either differs from its default the icon takes the tint and the
/// Inbox subtitle names what is hidden (`InboxView`), so a filtered Inbox
/// never passes for the whole Inbox. The label carries the state the way
/// podcast detail's filter menu does ("Filter Episodes, All Episodes"): the
/// toolbar keeps the icon only, and a toolbar menu drops a custom
/// accessibility value.
struct InboxFilterMenu: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let activeFilterTitles = appModel.inboxEpisodeListSettings.activeFilterTitles
        let summary = activeFilterTitles.isEmpty
            ? PodcastEpisodeFilter.all.title
            : activeFilterTitles.joined(separator: ", ")
        Menu {
            EpisodeFilterPicker(filter: filterBinding)
            Divider()
            Toggle(isOn: hidesQueuedEpisodesBinding) {
                Label("Hide Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        } label: {
            Label("Filter Episodes, \(summary)", systemImage: "line.3.horizontal.decrease")
                .foregroundStyle(activeFilterTitles.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        }
        // Toolbar items render monochrome unless the item carries its own
        // tint; a foreground color alone is flattened.
        .tint(activeFilterTitles.isEmpty ? nil : Color.accentColor)
    }

    private var filterBinding: Binding<PodcastEpisodeFilter> {
        Binding(
            get: { appModel.inboxEpisodeListSettings.filter },
            set: { filter in
                appModel.inboxEpisodeListSettings.setFilter(filter, modelContext: modelContext)
            }
        )
    }

    private var hidesQueuedEpisodesBinding: Binding<Bool> {
        Binding(
            get: { appModel.inboxEpisodeListSettings.hidesQueuedEpisodes },
            set: { hidesQueuedEpisodes in
                appModel.inboxEpisodeListSettings.setHidesQueuedEpisodes(
                    hidesQueuedEpisodes,
                    modelContext: modelContext
                )
            }
        )
    }
}
