import SwiftUI

struct HelpTopicHeaderView: View {
    let topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: topic.symbol)
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(topic.title)
                .font(.title.bold())

            Text(topic.summary)
                .foregroundStyle(.secondary)
        }
    }
}
