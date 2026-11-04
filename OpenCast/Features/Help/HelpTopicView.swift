import SwiftUI

struct HelpTopicView: View {
    /// Between the topic's blocks, and above the tab accessory at the end.
    nonisolated static let blockSpacing = 20.0

    @Environment(OpenCastAppModel.self) private var appModel

    let topicID: String

    var body: some View {
        let topic = appModel.helpContent.topic(topicID)
        Group {
            if let topic {
                topicContent(topic)
            } else {
                missingTopic
            }
        }
        .settingsSubscreen(title: topic?.title ?? "Help", rowSpacing: Self.blockSpacing)
    }

    private func topicContent(_ topic: HelpTopic) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Self.blockSpacing) {
                HelpTopicHeaderView(topic: topic)

                ForEach(topic.identifiedBlocks) { block in
                    HelpBlockView(block: block.block)
                }

                HelpRelatedTopicsView(ids: topic.related)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
        }
    }

    private var missingTopic: some View {
        ContentUnavailableView {
            Label("Topic Unavailable", systemImage: "questionmark.circle")
        } description: {
            Text("This help topic isn't available in this version of opencast.")
        } actions: {
            Link("Open Support", destination: OpenCastConstants.supportURL)
        }
    }
}
