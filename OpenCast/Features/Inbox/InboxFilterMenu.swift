import SwiftData
import SwiftUI

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
            Toggle(isOn: showsArchivedEpisodesBinding) {
                Label("Show Archived", systemImage: "archivebox")
            }
            Divider()
            // Not the Automatic layout's glyph, which sits in the next menu.
            Toggle(isOn: groupsByPodcastBinding) {
                Label("Group by Show", systemImage: "square.stack")
            }
        } label: {
            // The title carries the state: the toolbar shows the icon only, and a toolbar menu
            // drops a custom accessibility value.
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

    private var groupsByPodcastBinding: Binding<Bool> {
        Binding(
            get: { appModel.inboxEpisodeListSettings.groupsByPodcast },
            set: { groupsByPodcast in
                appModel.inboxEpisodeListSettings.setGroupsByPodcast(
                    groupsByPodcast,
                    modelContext: modelContext
                )
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

    private var showsArchivedEpisodesBinding: Binding<Bool> {
        Binding(
            get: { appModel.inboxEpisodeListSettings.showsArchivedEpisodes },
            set: { showsArchivedEpisodes in
                appModel.inboxEpisodeListSettings.setShowsArchivedEpisodes(
                    showsArchivedEpisodes,
                    modelContext: modelContext
                )
            }
        )
    }
}
