import SwiftUI

struct HelpHubView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        let helpContent = appModel.helpContent
        Group {
            if helpContent.visibleTopics.isEmpty {
                emptyState(loadErrorMessage: helpContent.loadErrorMessage)
            } else {
                topicList(helpContent.visibleTopics, updatedAt: helpContent.document.updatedAt)
            }
        }
        .settingsSubscreen(title: "Help")
        .task {
            await helpContent.refreshIfNeeded()
        }
    }

    private func topicList(_ topics: [HelpTopic], updatedAt: Date) -> some View {
        List {
            // A "Service Status" section slots in above the topics later.
            Section {
                ForEach(topics) { topic in
                    HelpTopicRow(topic: topic)
                }
            } footer: {
                Text("Updated \(updatedAt, format: .dateTime.month().day().year())")
            }
        }
    }

    private func emptyState(loadErrorMessage: String?) -> some View {
        ContentUnavailableView {
            Label("Help Unavailable", systemImage: "questionmark.circle")
        } description: {
            Text(loadErrorMessage ?? "No help topics are available for this version of opencast.")
        } actions: {
            Link("Open Support", destination: OpenCastConstants.supportURL)
        }
    }
}
